//! Length-checked binary IPC. The UI process never parses or lays out TeX.
//! A hung, overflowing, or out-of-memory renderer can be killed and restarted
//! without terminating the terminal. The worker contains no terminal state.
use super::*;
use std::{
    io::{self, Read, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread::JoinHandle,
    time::Duration,
};

const MAX_BYTES: usize = 16 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(2);

pub(super) struct Process {
    child: Child,
    input: ChildStdin,
    output: Receiver<Result<Image, String>>,
    reader: Option<JoinHandle<()>>,
}
impl Drop for Process {
    fn drop(&mut self) {
        #[cfg(unix)]
        unsafe {
            if self.child.try_wait().ok().flatten().is_none() {
                libc::kill(-(self.child.id() as i32), libc::SIGKILL);
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}
impl Process {
    pub(super) fn start(configured: &str) -> Result<Self, String> {
        let adjacent = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.join("ghosttex-math-worker")));
        let path = adjacent
            .filter(|p| p.is_file())
            .unwrap_or_else(|| PathBuf::from(configured));
        let mut command = Command::new(path);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
            // Only async-signal-safe operations run between fork and exec.
            unsafe {
                command.pre_exec(|| {
                    // Darwin reserves a large virtual address range for dyld
                    // and does not provide Linux's address-space semantics.
                    // Keep the IPC/output/deadline limits on every platform.
                    #[cfg(target_os = "linux")]
                    {
                        let memory = libc::rlimit {
                            rlim_cur: 768 * 1024 * 1024,
                            rlim_max: 768 * 1024 * 1024,
                        };
                        if libc::setrlimit(libc::RLIMIT_AS, &memory) != 0 {
                            return Err(io::Error::last_os_error());
                        }
                    }
                    let core = libc::rlimit {
                        rlim_cur: 0,
                        rlim_max: 0,
                    };
                    if libc::setrlimit(libc::RLIMIT_CORE, &core) != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        let mut child = command
            .spawn()
            .map_err(|e| format!("math worker unavailable: {e}"))?;
        let input = child.stdin.take().ok_or("math worker input unavailable")?;
        let mut output = child
            .stdout
            .take()
            .ok_or("math worker output unavailable")?;
        let (sender, receiver) = mpsc::channel();
        let reader = std::thread::spawn(move || loop {
            let result = read_result(&mut output);
            let failed = result.is_err();
            if sender.send(result).is_err() || failed {
                break;
            }
        });
        Ok(Self {
            child,
            input,
            output: receiver,
            reader: Some(reader),
        })
    }

    pub(super) fn render(
        &mut self,
        source: &str,
        options: &Options,
        canceled: impl Fn() -> bool,
    ) -> Result<Image, String> {
        let mut header = [0u8; 32];
        header[..4].copy_from_slice(b"GMT1");
        for (offset, value) in [
            (4, source.len() as u32),
            (8, options.font_px.to_bits()),
            (12, options.max_width),
            (16, options.max_height),
            (20, options.display),
        ] {
            header[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        header[24..28].copy_from_slice(&options.color);
        self.input
            .write_all(&header)
            .and_then(|_| self.input.write_all(source.as_bytes()))
            .and_then(|_| self.input.flush())
            .map_err(|e| format!("math worker input: {e}"))?;
        let start = std::time::Instant::now();
        loop {
            if canceled() {
                return Err("math worker canceled".into());
            }
            if start.elapsed() >= TIMEOUT {
                return Err("math worker timeout".into());
            }
            match self.output.recv_timeout(Duration::from_millis(5)) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => return Err("math worker exited".into()),
            }
        }
    }
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}
fn read_result(input: &mut impl Read) -> Result<Image, String> {
    let mut header = [0u8; 24];
    input
        .read_exact(&mut header)
        .map_err(|_| "math worker exited".to_owned())?;
    if &header[..4] != b"IMG1" {
        return Err("invalid math worker protocol".into());
    }
    let status = u32_at(&header, 4);
    let width = u32_at(&header, 8);
    let height = u32_at(&header, 12);
    let baseline = f32::from_bits(u32_at(&header, 16));
    let len = u32_at(&header, 20) as usize;
    if status != 0 {
        if len > 255 {
            return Err("invalid math worker error".into());
        }
        let mut message = vec![0u8; len];
        input.read_exact(&mut message).map_err(|e| e.to_string())?;
        return Err(String::from_utf8_lossy(&message).into_owned());
    }
    if width == 0
        || height == 0
        || width > 4096
        || height > 4096
        || len > MAX_BYTES
        || u64::from(width) * u64::from(height) * 4 != len as u64
        || !baseline.is_finite()
        || baseline < 0.0
        || baseline > height as f32
    {
        return Err("invalid worker image".into());
    }
    let mut pixels = vec![0u8; len];
    input.read_exact(&mut pixels).map_err(|e| e.to_string())?;
    Ok(Image {
        pixels,
        width,
        height,
        baseline,
    })
}

/// Worker executable entry point. Binary input is bounded before allocation;
/// each reply is one complete image or a short UTF-8 failure diagnostic.
pub fn run_worker() -> io::Result<()> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    loop {
        let mut header = [0u8; 32];
        match input.read_exact(&mut header) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(e) => return Err(e),
        }
        let len = u32_at(&header, 4) as usize;
        if &header[..4] != b"GMT1" || len == 0 || len > MAX_SOURCE || header[28..] != [0u8; 4] {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid worker request",
            ));
        }
        let mut source = vec![0u8; len];
        input.read_exact(&mut source)?;
        let options = Options {
            struct_size: std::mem::size_of::<Options>() as u32,
            version: 1,
            font_px: f32::from_bits(u32_at(&header, 8)),
            max_width: u32_at(&header, 12),
            max_height: u32_at(&header, 16),
            display: u32_at(&header, 20),
            color: header[24..28].try_into().unwrap(),
        };
        let image = std::panic::catch_unwind(AssertUnwindSafe(|| {
            let source = std::str::from_utf8(&source).map_err(|_| "invalid UTF-8".to_owned())?;
            render(source, &options)
        }))
        .unwrap_or_else(|_| Err("RaTeX panicked".into()));
        let mut reply = [0u8; 24];
        reply[..4].copy_from_slice(b"IMG1");
        let payload = match image {
            Ok(image) => {
                reply[8..12].copy_from_slice(&image.width.to_le_bytes());
                reply[12..16].copy_from_slice(&image.height.to_le_bytes());
                reply[16..20].copy_from_slice(&image.baseline.to_bits().to_le_bytes());
                image.pixels
            }
            Err(message) => {
                reply[4..8].copy_from_slice(&1u32.to_le_bytes());
                let mut end = message.len().min(255);
                while !message.is_char_boundary(end) {
                    end -= 1;
                }
                message.as_bytes()[..end].to_vec()
            }
        };
        reply[20..24].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        output.write_all(&reply)?;
        output.write_all(&payload)?;
        output.flush()?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_worker_output_cannot_allocate_unbounded_images() {
        let mut header = [0u8; 24];
        header[..4].copy_from_slice(b"IMG1");
        header[8..12].copy_from_slice(&u32::MAX.to_le_bytes());
        header[20..24].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(read_result(&mut header.as_slice()).is_err());
        header[..4].copy_from_slice(b"XXXX");
        assert!(read_result(&mut header.as_slice()).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn hung_worker_is_killed_and_cancellation_is_prompt() {
        use std::os::unix::fs::PermissionsExt;
        let path =
            std::env::temp_dir().join(format!("ghosttex-hung-worker-{}", std::process::id()));
        std::fs::write(&path, "#!/bin/sh\nsleep 30\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let start = std::time::Instant::now();
        {
            let mut process = Process::start(path.to_str().unwrap()).unwrap();
            let error = process
                .render("x", &crate::tests::options(true), || false)
                .err()
                .unwrap();
            assert!(error.contains("timeout"));
        }
        assert!(start.elapsed() < Duration::from_secs(4));
        let start = std::time::Instant::now();
        {
            let mut process = Process::start(path.to_str().unwrap()).unwrap();
            let error = process
                .render("x", &crate::tests::options(true), || true)
                .err()
                .unwrap();
            assert!(error.contains("canceled"));
        }
        assert!(start.elapsed() < Duration::from_secs(1));
        std::fs::remove_file(path).unwrap();
    }
}
