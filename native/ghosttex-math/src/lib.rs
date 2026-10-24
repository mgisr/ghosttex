//! Native, bounded RaTeX -> glyph outlines -> straight-alpha sRGB RGBA8.
//! No PNG encoding, terminal escape sequences, external TeX, or file imports.
//! Rust allocations are released only by ghosttex_math_free. ABI version 1.
use std::{collections::HashMap, ffi::c_void, panic::AssertUnwindSafe, sync::Arc};

use ab_glyph::{Font, ScaleFont};
use ratex_font::FontId;
use ratex_font_loader::SystemFontResolver;
use ratex_layout::{
    layout_with_fallback_metrics, to_display_list, validate_layout, FallbackGlyphMetrics,
    LayoutOptions,
};
use ratex_types::{color::Color, math_style::MathStyle};
use resvg::{tiny_skia, usvg};
mod process;
mod service;
pub use process::run_worker;

const MAX_SOURCE: usize = 16 * 1024;
const MAX_ITEMS: usize = 4096;
const MAX_SVG: usize = 8 * 1024 * 1024;
const MAX_PIXELS: u64 = 4 * 1024 * 1024;

#[repr(C)]
pub struct Options {
    pub struct_size: u32,
    pub version: u32,
    pub font_px: f32,
    pub max_width: u32,
    pub max_height: u32,
    pub display: u32,
    pub color: [u8; 4],
}

#[repr(C)]
pub struct ResultImage {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub baseline: f32,
    pub data: *const u8,
    pub len: usize,
    pub owner: *mut c_void,
    /// UTF-8 diagnostic, zero terminated. Owned by this result, not thread local.
    pub error: [u8; 256],
}

impl Default for ResultImage {
    fn default() -> Self {
        Self {
            width: 0,
            height: 0,
            stride: 0,
            baseline: 0.0,
            data: std::ptr::null(),
            len: 0,
            owner: std::ptr::null_mut(),
            error: [0; 256],
        }
    }
}

struct Image {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    baseline: f32,
}

#[no_mangle]
pub extern "C" fn ghosttex_math_abi_version() -> u32 {
    1
}

/// source points to len readable bytes, opts/out to initialized aligned storage.
/// out must not own a previous result. Success is 0; all errors leave source
/// available to the caller and put a diagnostic in out. No panic crosses C ABI.
///
/// # Safety
/// Pointers must meet the above contract for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_render(
    source: *const u8,
    len: usize,
    opts: *const Options,
    out: *mut ResultImage,
) -> i32 {
    if out.is_null() || !out.is_aligned() {
        return 1;
    }
    unsafe {
        out.write(ResultImage::default());
    }
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        if source.is_null() || len == 0 || len > MAX_SOURCE || opts.is_null() || !opts.is_aligned()
        {
            return Err("invalid source or options".to_owned());
        }
        let opts = unsafe { &*opts };
        let bytes = unsafe { std::slice::from_raw_parts(source, len) };
        let tex = std::str::from_utf8(bytes).map_err(|_| "invalid UTF-8".to_owned())?;
        render(tex, opts)
    }));
    match result {
        Ok(Ok(image)) => {
            unsafe {
                out.write(image_result(Arc::new(image)));
            }
            0
        }
        other => {
            let message = match other {
                Ok(Err(e)) => e,
                _ => "RaTeX panicked".to_owned(),
            };
            let mut end = message.len().min(255);
            while !message.is_char_boundary(end) {
                end -= 1;
            }
            unsafe {
                (&mut (*out).error)[..end].copy_from_slice(&message.as_bytes()[..end]);
            }
            1
        }
    }
}

/// # Safety
/// result is an aligned, live result returned by ghosttex_math_render. A result
/// may be freed twice in place, but copies of an owning result must not be freed.
#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_free(result: *mut ResultImage) {
    if result.is_null() || !result.is_aligned() {
        return;
    }
    let image = unsafe { &mut *result };
    if !image.owner.is_null() {
        unsafe {
            drop(Box::from_raw(image.owner.cast::<Arc<Image>>()));
        }
    }
    *image = ResultImage::default();
}

fn image_result(image: Arc<Image>) -> ResultImage {
    ResultImage {
        width: image.width,
        height: image.height,
        stride: image.width * 4,
        baseline: image.baseline,
        data: image.pixels.as_ptr(),
        len: image.pixels.len(),
        owner: Box::into_raw(Box::new(image)).cast(),
        ..Default::default()
    }
}

fn render(tex: &str, opts: &Options) -> Result<Image, String> {
    if opts.version != 1
        || opts.struct_size as usize != std::mem::size_of::<Options>()
        || !opts.font_px.is_finite()
        || !(4.0..=256.0).contains(&opts.font_px)
        || opts.max_width == 0
        || opts.max_width > 4096
        || opts.max_height == 0
        || opts.max_height > 4096
        || opts.display > 1
    {
        return Err("unsupported ABI or render options".into());
    }
    // Custom macros and I/O are deliberately outside the host contract.
    for command in [
        "\\def",
        "\\gdef",
        "\\edef",
        "\\xdef",
        "\\let",
        "\\futurelet",
        "\\newcommand",
        "\\renewcommand",
        "\\providecommand",
        "\\include",
        "\\input",
    ] {
        if tex.contains(command) {
            return Err("macros and external input are disabled".into());
        }
    }
    if tex.contains('\0') {
        return Err("NUL in TeX source".into());
    }
    let nodes = ratex_parser::parse(tex).map_err(|e| format!("parse: {e}"))?;
    let systems = SystemFontResolver::new();
    let mut metrics = HashMap::new();
    for ch in tex.chars().filter(|c| !c.is_ascii() && !c.is_whitespace()) {
        if metrics.contains_key(&ch) {
            continue;
        }
        for id in [
            FontId::CjkRegular,
            FontId::CjkFallback,
            FontId::EmojiFallback,
        ] {
            let Some(font) = systems.get(id)? else {
                continue;
            };
            let font = font.font();
            let glyph = font.glyph_id(ch);
            if glyph.0 == 0 {
                continue;
            }
            // ab_glyph scales by typographic height; SVG outlines scale by em.
            let units = font.units_per_em().ok_or("font has no em units")?;
            let scale = font.height_unscaled() / units;
            let scaled = font.as_scaled(scale);
            let bounds = font.glyph_bounds(&glyph.with_scale(scale));
            metrics.insert(
                ch,
                FallbackGlyphMetrics {
                    width: scaled.h_advance(glyph) as f64,
                    height: (-bounds.min.y).max(0.0) as f64,
                    depth: bounds.max.y.max(0.0) as f64,
                },
            );
            break;
        }
    }
    let color = opts.color.map(|c| c as f32 / 255.0);
    let layout_options = LayoutOptions::default()
        .with_style(if opts.display == 1 {
            MathStyle::Display
        } else {
            MathStyle::Text
        })
        .with_color(Color::new(color[0], color[1], color[2], color[3]));
    let tree = layout_with_fallback_metrics(&nodes, &layout_options, Arc::new(metrics));
    validate_layout(&tree)?;
    let list = to_display_list(&tree);
    if list.items.len() > MAX_ITEMS {
        return Err("too many drawing items".into());
    }
    for value in [
        list.width,
        list.height,
        list.depth,
        list.height + list.depth,
    ] {
        if !value.is_finite() || value < 0.0 {
            return Err("invalid layout metrics".into());
        }
    }
    let padding = 2.0;
    let max_width = f64::from(opts.max_width).max(1.0);
    let natural_width = list.width * f64::from(opts.font_px);
    let scale = ((max_width - 2.0 * padding).max(1.0) / natural_width.max(1.0)).min(1.0);
    if scale < 0.5 {
        return Err("formula too wide at readable size".into());
    }
    let font_px = f64::from(opts.font_px) * scale;
    let width = (list.width * font_px + 2.0 * padding).ceil().max(1.0);
    let height = ((list.height + list.depth) * font_px + 2.0 * padding)
        .ceil()
        .max(1.0);
    if width > max_width
        || height > f64::from(opts.max_height)
        || width * height > MAX_PIXELS as f64
    {
        return Err("formula exceeds image budget".into());
    }
    let svg = ratex_svg::render_to_svg_with_color_syntax(
        &list,
        &ratex_svg::SvgOptions {
            font_size: font_px,
            padding,
            embed_glyphs: true,
            ..Default::default()
        },
        ratex_svg::SvgColorSyntax::Rgb,
    );
    // The outlined renderer falls back to text when a glyph is unavailable.
    // Refuse partial rendering instead of silently dropping missing glyphs.
    if svg.len() > MAX_SVG || svg.contains("<text") {
        return Err("font unavailable or SVG budget exceeded".into());
    }
    let options = usvg::Options {
        dpi: 72.0,
        ..Default::default()
    };
    let tree = usvg::Tree::from_str(&svg, &options).map_err(|e| format!("SVG: {e}"))?;
    let (width, height) = (width as u32, height as u32);
    let mut pixels = tiny_skia::Pixmap::new(width, height).ok_or("cannot allocate RGBA")?;
    resvg::render(
        &tree,
        tiny_skia::Transform::identity(),
        &mut pixels.as_mut(),
    );
    let mut pixels = pixels.take();
    // tiny-skia uses premultiplied sRGB. Ghostty expects straight alpha and
    // performs its own premultiplication in both native image shaders.
    for pixel in pixels.chunks_exact_mut(4) {
        let alpha = u32::from(pixel[3]);
        if alpha > 0 {
            for c in &mut pixel[..3] {
                *c = ((u32::from(*c) * 255 + alpha / 2) / alpha).min(255) as u8;
            }
        }
    }
    Ok(Image {
        pixels,
        width,
        height,
        baseline: (padding + list.height * font_px) as f32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    pub(crate) fn options(display: bool) -> Options {
        Options {
            struct_size: std::mem::size_of::<Options>() as u32,
            version: 1,
            font_px: 24.0,
            max_width: 1024,
            max_height: 1024,
            display: display as u32,
            color: [220, 230, 240, 255],
        }
    }
    #[test]
    fn native_formula_corpus() {
        for source in [
            r"\frac{a_1^2}{\sqrt{b}}",
            r"x^{y_z}+\sum_{i=1}^{n}i",
            r"\begin{pmatrix}a&b\\c&d\end{pmatrix}",
            r"f(x)=\begin{cases}x^2&x>0\\0&x\le0\end{cases}",
            r"\begin{aligned}a&=b+c\\d&=e\end{aligned}",
            r"\text{energy}\quad E=mc^2",
            r"\color{red}{x}+\sqrt[3]{y}",
        ] {
            for display in [false, true] {
                let image =
                    render(source, &options(display)).unwrap_or_else(|e| panic!("{source}: {e}"));
                assert_eq!(
                    image.pixels.len(),
                    (image.width * image.height * 4) as usize
                );
                assert!(image.baseline > 0.0 && image.baseline <= image.height as f32);
                assert!(image.pixels.chunks_exact(4).any(|p| p[3] > 0));
                assert!(image.pixels.chunks_exact(4).any(|p| p[3] == 0));
            }
        }
    }
    #[test]
    fn errors_limits_and_ffi_ownership() {
        for tex in [
            r"\notAGhosttexCommand{x}",
            r"\frac{",
            r"\def\x{x}\x",
            "x\0y",
        ] {
            assert!(render(tex, &options(true)).is_err(), "{tex}");
        }
        let mut small = options(true);
        small.max_width = 8;
        assert!(render(r"\frac{123456}{789}", &small).is_err());
        small = options(true);
        small.max_height = 4;
        assert!(render(r"\frac{x}{y}", &small).is_err());
        small = options(true);
        small.font_px = f32::NAN;
        assert!(render("x", &small).is_err());
        let source = r"\frac{x}{y}";
        for _ in 0..100 {
            let mut out = ResultImage::default();
            assert_eq!(
                unsafe {
                    ghosttex_math_render(source.as_ptr(), source.len(), &options(true), &mut out)
                },
                0
            );
            assert!(!out.owner.is_null());
            unsafe {
                ghosttex_math_free(&mut out);
                ghosttex_math_free(&mut out);
            }
            assert!(out.data.is_null());
        }
        let mut out = ResultImage::default();
        assert_ne!(
            unsafe { ghosttex_math_render(std::ptr::null(), usize::MAX, &options(true), &mut out) },
            0
        );
        assert!(out.data.is_null() && out.error[0] != 0);
        let bad = [0xff];
        assert_ne!(
            unsafe { ghosttex_math_render(bad.as_ptr(), 1, &options(true), &mut out) },
            0
        );
        assert!(render(&"{".repeat(1000), &options(true)).is_err());
    }
}
