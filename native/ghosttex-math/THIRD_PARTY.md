# Native math dependencies

Versions and licenses are recorded from Cargo.lock. RaTeX is fixed at
`28fa5a7c800172af00043270c0acc85bd0c60155`. Embedded KaTeX fonts use SIL OFL;
see licenses/KaTeX-fonts.txt and its notice. System Unicode fonts are supplied by
the host and are not bundled.

resvg uses MPL-2.0; its unmodified corresponding source is available at the
versioned upstream URL below. Other crates retain their listed licenses.
Collected upstream notices are installed with native builds.

| Dependency                 | Version | License                             | Upstream                                                                    |
| -------------------------- | ------- | ----------------------------------- | --------------------------------------------------------------------------- |
| ab_glyph                   | 0.2.32  | Apache-2.0                          | https://github.com/alexheretic/ab-glyph                                     |
| ab_glyph_rasterizer        | 0.1.10  | Apache-2.0                          | https://github.com/alexheretic/ab-glyph                                     |
| adler2                     | 2.0.1   | 0BSD OR MIT OR Apache-2.0           | https://github.com/oyvindln/adler2                                          |
| aho-corasick               | 1.1.5   | Unlicense OR MIT                    | https://github.com/BurntSushi/aho-corasick                                  |
| arrayref                   | 0.3.9   | BSD-2-Clause                        | https://github.com/droundy/arrayref                                         |
| arrayvec                   | 0.7.8   | MIT OR Apache-2.0                   | https://github.com/bluss/arrayvec                                           |
| autocfg                    | 1.5.1   | Apache-2.0 OR MIT                   | https://github.com/cuviper/autocfg                                          |
| base64                     | 0.22.1  | MIT OR Apache-2.0                   | https://github.com/marshallpierce/rust-base64                               |
| bit-set                    | 0.8.0   | Apache-2.0 OR MIT                   | https://github.com/contain-rs/bit-set                                       |
| bit-vec                    | 0.8.0   | Apache-2.0 OR MIT                   | https://github.com/contain-rs/bit-vec                                       |
| bitflags                   | 1.3.2   | MIT/Apache-2.0                      | https://github.com/bitflags/bitflags                                        |
| block-buffer               | 0.12.1  | MIT OR Apache-2.0                   | https://github.com/RustCrypto/utils                                         |
| bumpalo                    | 3.20.3  | MIT OR Apache-2.0                   | https://github.com/fitzgen/bumpalo                                          |
| bytemuck                   | 1.25.2  | Zlib OR Apache-2.0 OR MIT           | https://github.com/Lokathor/bytemuck                                        |
| byteorder-lite             | 0.1.0   | Unlicense OR MIT                    | https://github.com/image-rs/byteorder-lite                                  |
| cfg-if                     | 1.0.5   | MIT OR Apache-2.0                   | https://github.com/rust-lang/cfg-if                                         |
| color_quant                | 1.1.0   | MIT                                 | https://github.com/image-rs/color_quant.git                                 |
| const-oid                  | 0.10.2  | Apache-2.0 OR MIT                   | https://github.com/RustCrypto/formats                                       |
| core_maths                 | 0.1.1   | MIT                                 | https://github.com/robertbastian/core_maths                                 |
| cpufeatures                | 0.3.1   | MIT OR Apache-2.0                   | https://github.com/RustCrypto/utils                                         |
| crc32fast                  | 1.5.3   | MIT OR Apache-2.0                   | https://github.com/srijs/rust-crc32fast                                     |
| crypto-common              | 0.2.2   | MIT OR Apache-2.0                   | https://github.com/RustCrypto/traits                                        |
| data-url                   | 0.3.2   | MIT OR Apache-2.0                   | https://github.com/servo/rust-url                                           |
| digest                     | 0.11.3  | MIT OR Apache-2.0                   | https://github.com/RustCrypto/traits                                        |
| euclid                     | 0.22.14 | MIT OR Apache-2.0                   | https://github.com/servo/euclid                                             |
| fancy-regex                | 0.14.0  | MIT                                 | https://github.com/fancy-regex/fancy-regex                                  |
| fdeflate                   | 0.3.7   | MIT OR Apache-2.0                   | https://github.com/image-rs/fdeflate                                        |
| flate2                     | 1.1.10  | MIT OR Apache-2.0                   | https://github.com/rust-lang/flate2-rs                                      |
| float-cmp                  | 0.9.0   | MIT                                 | https://github.com/mikedilger/float-cmp                                     |
| fontconfig-parser          | 0.5.8   | MIT                                 | https://github.com/Riey/fontconfig-parser                                   |
| fontdb                     | 0.23.0  | MIT                                 | https://github.com/RazrFalcon/fontdb                                        |
| futures-core               | 0.3.34  | MIT OR Apache-2.0                   | https://github.com/rust-lang/futures-rs                                     |
| futures-task               | 0.3.34  | MIT OR Apache-2.0                   | https://github.com/rust-lang/futures-rs                                     |
| futures-util               | 0.3.34  | MIT OR Apache-2.0                   | https://github.com/rust-lang/futures-rs                                     |
| gif                        | 0.13.3  | MIT OR Apache-2.0                   | https://github.com/image-rs/image-gif                                       |
| hybrid-array               | 0.4.15  | MIT OR Apache-2.0                   | https://github.com/RustCrypto/hybrid-array                                  |
| image-webp                 | 0.2.4   | MIT OR Apache-2.0                   | https://github.com/image-rs/image-webp                                      |
| imagesize                  | 0.13.0  | MIT                                 | https://github.com/Roughsketch/imagesize                                    |
| itoa                       | 1.0.18  | MIT OR Apache-2.0                   | https://github.com/dtolnay/itoa                                             |
| js-sys                     | 0.3.106 | MIT OR Apache-2.0                   | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/js-sys      |
| kurbo                      | 0.11.3  | Apache-2.0 OR MIT                   | https://github.com/linebender/kurbo                                         |
| libc                       | 0.2.191 | MIT OR Apache-2.0                   | https://github.com/rust-lang/libc                                           |
| libm                       | 0.2.16  | MIT                                 | https://github.com/rust-lang/compiler-builtins                              |
| log                        | 0.4.34  | MIT OR Apache-2.0                   | https://github.com/rust-lang/log                                            |
| memchr                     | 2.8.3   | Unlicense OR MIT                    | https://github.com/BurntSushi/memchr                                        |
| memmap2                    | 0.9.12  | MIT OR Apache-2.0                   | https://github.com/RazrFalcon/memmap2-rs                                    |
| mime                       | 0.3.17  | MIT OR Apache-2.0                   | https://github.com/hyperium/mime                                            |
| mime_guess                 | 2.0.5   | MIT                                 | https://github.com/abonander/mime_guess                                     |
| miniz_oxide                | 0.8.9   | MIT OR Zlib OR Apache-2.0           | https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide               |
| miniz_oxide                | 0.9.1   | MIT OR Zlib OR Apache-2.0           | https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide               |
| num-traits                 | 0.2.19  | MIT OR Apache-2.0                   | https://github.com/rust-num/num-traits                                      |
| once_cell                  | 1.21.4  | MIT OR Apache-2.0                   | https://github.com/matklad/once_cell                                        |
| owned_ttf_parser           | 0.25.1  | Apache-2.0                          | https://github.com/alexheretic/owned-ttf-parser                             |
| phf                        | 0.11.3  | MIT                                 | https://github.com/rust-phf/rust-phf                                        |
| phf_generator              | 0.11.3  | MIT                                 | https://github.com/rust-phf/rust-phf                                        |
| phf_macros                 | 0.11.3  | MIT                                 | https://github.com/rust-phf/rust-phf                                        |
| phf_shared                 | 0.11.3  | MIT                                 | https://github.com/rust-phf/rust-phf                                        |
| pico-args                  | 0.5.0   | MIT                                 | https://github.com/RazrFalcon/pico-args                                     |
| pin-project-lite           | 0.2.17  | Apache-2.0 OR MIT                   | https://github.com/taiki-e/pin-project-lite                                 |
| png                        | 0.17.16 | MIT OR Apache-2.0                   | https://github.com/image-rs/image-png                                       |
| proc-macro2                | 1.0.107 | MIT OR Apache-2.0                   | https://github.com/dtolnay/proc-macro2                                      |
| quick-error                | 2.0.1   | MIT/Apache-2.0                      | http://github.com/tailhook/quick-error                                      |
| quote                      | 1.0.47  | MIT OR Apache-2.0                   | https://github.com/dtolnay/quote                                            |
| rand                       | 0.8.8   | MIT OR Apache-2.0                   | https://github.com/rust-random/rand                                         |
| rand_core                  | 0.6.4   | MIT OR Apache-2.0                   | https://github.com/rust-random/rand                                         |
| ratex-font                 | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-font-loader          | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-katex-fonts          | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-layout               | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-lexer                | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-parser               | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-svg                  | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-types                | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| ratex-unicode-font         | 0.1.15  | MIT                                 | https://github.com/erweixin/RaTeX                                           |
| regex                      | 1.13.1  | MIT OR Apache-2.0                   | https://github.com/rust-lang/regex                                          |
| regex-automata             | 0.4.18  | MIT OR Apache-2.0                   | https://github.com/rust-lang/regex                                          |
| regex-lite                 | 0.1.9   | MIT OR Apache-2.0                   | https://github.com/rust-lang/regex                                          |
| regex-syntax               | 0.8.11  | MIT OR Apache-2.0                   | https://github.com/rust-lang/regex                                          |
| resvg                      | 0.45.1  | Apache-2.0 OR MIT                   | https://github.com/linebender/resvg                                         |
| rgb                        | 0.8.53  | MIT                                 | https://github.com/kornelski/rust-rgb                                       |
| roxmltree                  | 0.20.0  | MIT OR Apache-2.0                   | https://github.com/RazrFalcon/roxmltree                                     |
| rust-embed                 | 8.13.0  | MIT                                 | https://pyrossh.dev/repos/rust-embed                                        |
| rust-embed-impl            | 8.13.0  | MIT                                 | https://pyrossh.dev/repos/rust-embed                                        |
| rust-embed-utils           | 8.13.0  | MIT                                 | https://pyrossh.dev/repos/rust-embed                                        |
| rustversion                | 1.0.23  | MIT OR Apache-2.0                   | https://github.com/dtolnay/rustversion                                      |
| same-file                  | 1.0.6   | Unlicense/MIT                       | https://github.com/BurntSushi/same-file                                     |
| serde                      | 1.0.229 | MIT OR Apache-2.0                   | https://github.com/serde-rs/serde                                           |
| serde_core                 | 1.0.229 | MIT OR Apache-2.0                   | https://github.com/serde-rs/serde                                           |
| serde_derive               | 1.0.229 | MIT OR Apache-2.0                   | https://github.com/serde-rs/serde                                           |
| serde_json                 | 1.0.154 | MIT OR Apache-2.0                   | https://github.com/serde-rs/json                                            |
| sha2                       | 0.11.1  | MIT OR Apache-2.0                   | https://github.com/RustCrypto/hashes                                        |
| simd-adler32               | 0.3.10  | MIT                                 | https://github.com/mcountryman/simd-adler32                                 |
| simplecss                  | 0.2.2   | Apache-2.0 OR MIT                   | https://github.com/linebender/simplecss                                     |
| siphasher                  | 1.0.4   | MIT OR Apache-2.0                   | https://github.com/jedisct1/rust-siphash                                    |
| slab                       | 0.4.12  | MIT                                 | https://github.com/tokio-rs/slab                                            |
| slotmap                    | 1.1.1   | Zlib                                | https://github.com/orlp/slotmap                                             |
| smallvec                   | 1.16.4  | MIT OR Apache-2.0                   | https://github.com/servo/rust-smallvec                                      |
| strict-num                 | 0.1.1   | MIT                                 | https://github.com/RazrFalcon/strict-num                                    |
| svgtypes                   | 0.15.3  | Apache-2.0 OR MIT                   | https://github.com/linebender/svgtypes                                      |
| syn                        | 2.0.119 | MIT OR Apache-2.0                   | https://github.com/dtolnay/syn                                              |
| syn                        | 3.0.9   | MIT OR Apache-2.0                   | https://github.com/dtolnay/syn                                              |
| sys-locale                 | 0.3.2   | MIT OR Apache-2.0                   | https://github.com/1Password/sys-locale                                     |
| system-fonts               | 0.1.2   | MIT OR Apache-2.0                   | https://github.com/yijehyung/system-fonts                                   |
| thiserror                  | 1.0.69  | MIT OR Apache-2.0                   | https://github.com/dtolnay/thiserror                                        |
| thiserror-impl             | 1.0.69  | MIT OR Apache-2.0                   | https://github.com/dtolnay/thiserror                                        |
| tiny-skia                  | 0.11.4  | BSD-3-Clause                        | https://github.com/RazrFalcon/tiny-skia                                     |
| tiny-skia-path             | 0.11.4  | BSD-3-Clause                        | https://github.com/RazrFalcon/tiny-skia/tree/master/path                    |
| tinyvec                    | 1.13.3  | Zlib OR Apache-2.0 OR MIT           | https://github.com/Lokathor/tinyvec                                         |
| ttf-parser                 | 0.25.1  | MIT OR Apache-2.0                   | https://github.com/harfbuzz/ttf-parser                                      |
| typenum                    | 1.20.1  | MIT OR Apache-2.0                   | https://github.com/paholg/typenum                                           |
| unicase                    | 2.10.0  | MIT OR Apache-2.0                   | https://github.com/seanmonstar/unicase                                      |
| unicode-ident              | 1.0.27  | (MIT OR Apache-2.0) AND Unicode-3.0 | https://github.com/dtolnay/unicode-ident                                    |
| unicode-normalization      | 0.1.26  | (MIT OR Apache-2.0) AND Unicode-3.0 | https://github.com/unicode-rs/unicode-normalization                         |
| usvg                       | 0.45.1  | Apache-2.0 OR MIT                   | https://github.com/linebender/resvg                                         |
| version_check              | 0.9.5   | MIT/Apache-2.0                      | https://github.com/SergioBenitez/version_check                              |
| walkdir                    | 2.5.0   | Unlicense/MIT                       | https://github.com/BurntSushi/walkdir                                       |
| wasm-bindgen               | 0.2.129 | MIT OR Apache-2.0                   | https://github.com/wasm-bindgen/wasm-bindgen                                |
| wasm-bindgen-macro         | 0.2.129 | MIT OR Apache-2.0                   | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/macro       |
| wasm-bindgen-macro-support | 0.2.129 | MIT OR Apache-2.0                   | https://github.com/wasm-bindgen/wasm-bindgen/tree/main/crates/macro-support |
| wasm-bindgen-shared        | 0.2.129 | MIT OR Apache-2.0                   | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/shared      |
| web-sys                    | 0.3.106 | MIT OR Apache-2.0                   | https://github.com/wasm-bindgen/wasm-bindgen/tree/master/crates/web-sys     |
| weezl                      | 0.1.12  | MIT OR Apache-2.0                   | https://github.com/image-rs/weezl                                           |
| winapi-util                | 0.1.11  | Unlicense OR MIT                    | https://github.com/BurntSushi/winapi-util                                   |
| windows-link               | 0.2.1   | MIT OR Apache-2.0                   | https://github.com/microsoft/windows-rs                                     |
| windows-sys                | 0.61.2  | MIT OR Apache-2.0                   | https://github.com/microsoft/windows-rs                                     |
| xmlwriter                  | 0.1.0   | MIT                                 | https://github.com/RazrFalcon/xmlwriter                                     |
| zlib-rs                    | 0.6.8   | Zlib                                | https://github.com/trifectatechfoundation/zlib-rs                           |
| zmij                       | 1.0.23  | MIT                                 | https://github.com/dtolnay/zmij                                             |
| zune-core                  | 0.4.12  | MIT OR Apache-2.0 OR Zlib           | https://crates.io/crates/zune-core/0.4.12                                   |
| zune-jpeg                  | 0.4.21  | MIT OR Apache-2.0 OR Zlib           | https://github.com/etemesi254/zune-image/tree/dev/crates/zune-jpeg          |
