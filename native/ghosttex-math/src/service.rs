//! One process-wide worker, bounded queue and LRU. Surfaces hold leases on their
//! current frame's requests. Unreferenced queued work is skipped before parsing.
use super::*;
use std::{
    collections::{HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Condvar, LazyLock, Mutex, Weak,
    },
    thread::JoinHandle,
    time::Instant,
};

const MAX_QUEUE: usize = 32;
const MAX_ENTRIES: usize = 512;
const MAX_BYTES: usize = 64 * 1024 * 1024;
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
type Wake = unsafe extern "C" fn(*mut c_void);
type Outcome = Result<Arc<Image>, String>;

#[derive(Clone, PartialEq, Eq, Hash)]
struct Key {
    source: String,
    font: u32,
    width: u32,
    height: u32,
    display: u32,
    color: [u8; 4],
}
impl Key {
    fn new(source: &str, o: &Options) -> Self {
        Self {
            source: source.into(),
            font: o.font_px.to_bits(),
            width: o.max_width,
            height: o.max_height,
            display: o.display,
            color: o.color,
        }
    }
    fn options(&self) -> Options {
        Options {
            struct_size: std::mem::size_of::<Options>() as u32,
            version: 1,
            font_px: f32::from_bits(self.font),
            max_width: self.width,
            max_height: self.height,
            display: self.display,
            color: self.color,
        }
    }
}
struct Entry {
    id: u64,
    key: Key,
    users: HashSet<u64>,
    used: u64,
    result: Option<Outcome>,
}
struct Notifier {
    callback: Mutex<Option<(Wake, usize)>>,
}
impl Notifier {
    fn notify(&self) {
        if let Some((callback, userdata)) = *self.callback.lock().unwrap() {
            unsafe {
                callback(userdata as *mut c_void);
            }
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Stats {
    renders: u64,
    cache_hits: u64,
    canceled: u64,
    failures: u64,
    render_ns: u64,
    cpu_bytes: u64,
    queued: u64,
}
struct State {
    entries: Vec<Entry>,
    queue: VecDeque<u64>,
    contexts: HashMap<u64, Arc<Notifier>>,
    tick: u64,
    stop: bool,
    stats: Stats,
}
struct Core {
    state: Mutex<State>,
    ready: Condvar,
    stopping: AtomicBool,
}
struct Service {
    core: Arc<Core>,
    worker: Mutex<Option<JoinHandle<()>>>,
}
impl Drop for Service {
    fn drop(&mut self) {
        self.core.state.lock().unwrap().stop = true;
        self.core.stopping.store(true, Ordering::Relaxed);
        self.core.ready.notify_all();
        if let Some(worker) = self.worker.lock().unwrap().take() {
            let _ = worker.join();
        }
    }
}
static SERVICE: LazyLock<Mutex<Weak<Service>>> = LazyLock::new(|| Mutex::new(Weak::new()));
fn service(worker_path: &str) -> Option<Arc<Service>> {
    let mut shared = SERVICE.lock().unwrap();
    if let Some(service) = shared.upgrade() {
        return Some(service);
    }
    let core = Arc::new(Core {
        state: Mutex::new(State {
            entries: Vec::new(),
            queue: VecDeque::new(),
            contexts: HashMap::new(),
            tick: 0,
            stop: false,
            stats: Stats::default(),
        }),
        ready: Condvar::new(),
        stopping: AtomicBool::new(false),
    });
    let background = core.clone();
    let worker_path = worker_path.to_owned();
    let worker = std::thread::Builder::new()
        .name("ghosttex-math".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || work(background, worker_path))
        .ok()?;
    let service = Arc::new(Service {
        core,
        worker: Mutex::new(Some(worker)),
    });
    *shared = Arc::downgrade(&service);
    Some(service)
}

pub struct Context {
    service: Arc<Service>,
    id: u64,
    notifier: Arc<Notifier>,
    previous: HashSet<u64>,
    current: HashSet<u64>,
}
impl Drop for Context {
    fn drop(&mut self) {
        // Wait out any in-flight notification before the host frees its wakeup.
        *self.notifier.callback.lock().unwrap() = None;
        let mut state = self.service.core.state.lock().unwrap();
        state.contexts.remove(&self.id);
        for entry in &mut state.entries {
            entry.users.remove(&self.id);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_context_create(
    callback: Option<Wake>,
    userdata: *mut c_void,
    path: *const u8,
    path_len: usize,
) -> *mut Context {
    if path.is_null() || path_len > 4096 {
        return std::ptr::null_mut();
    }
    let Ok(path) = std::str::from_utf8(unsafe { std::slice::from_raw_parts(path, path_len) })
    else {
        return std::ptr::null_mut();
    };
    let Some(service) = service(path) else {
        return std::ptr::null_mut();
    };
    let notifier = Arc::new(Notifier {
        callback: Mutex::new(callback.map(|c| (c, userdata as usize))),
    });
    let id = {
        let mut state = service.core.state.lock().unwrap();
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        state.contexts.insert(id, notifier.clone());
        id
    };
    Box::into_raw(Box::new(Context {
        service,
        id,
        notifier,
        previous: HashSet::new(),
        current: HashSet::new(),
    }))
}

/// # Safety
/// Context must be live and exclusively accessed by the calling host thread.
#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_context_destroy(context: *mut Context) {
    if !context.is_null() {
        unsafe {
            drop(Box::from_raw(context));
        }
    }
}
/// # Safety
/// Same context contract. Begin/finish bracket one frame of request calls.
#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_frame_begin(context: *mut Context) {
    if let Some(context) = unsafe { context.as_mut() } {
        context.current.clear();
    }
}
/// # Safety
/// Same context contract.
#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_frame_finish(context: *mut Context) {
    let Some(context) = (unsafe { context.as_mut() }) else {
        return;
    };
    let mut state = context.service.core.state.lock().unwrap();
    for entry in &mut state.entries {
        if context.previous.contains(&entry.id) && !context.current.contains(&entry.id) {
            entry.users.remove(&context.id);
        }
    }
    std::mem::swap(&mut context.previous, &mut context.current);
}
/// 0 ready, 1 failed, 2 pending or queue full. out follows the synchronous ABI.
/// # Safety
/// Context is exclusive; input/output pointers follow ghosttex_math_render.
#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_request(
    context: *mut Context,
    source: *const u8,
    len: usize,
    options: *const Options,
    out: *mut ResultImage,
    ticket: *mut u64,
) -> i32 {
    if context.is_null()
        || source.is_null()
        || options.is_null()
        || out.is_null()
        || ticket.is_null()
        || len == 0
        || len > MAX_SOURCE
    {
        return 1;
    }
    let context = unsafe { &mut *context };
    let options = unsafe { &*options };
    unsafe {
        out.write(ResultImage::default());
        ticket.write(0);
    }
    if options.version != 1 || options.struct_size as usize != std::mem::size_of::<Options>() {
        return 1;
    }
    let Ok(source) = std::str::from_utf8(unsafe { std::slice::from_raw_parts(source, len) }) else {
        return 1;
    };
    let key = Key::new(source, options);
    let mut state = context.service.core.state.lock().unwrap();
    state.tick += 1;
    let tick = state.tick;
    if let Some(index) = state.entries.iter().position(|e| e.key == key) {
        let entry = &mut state.entries[index];
        entry.used = tick;
        entry.users.insert(context.id);
        context.current.insert(entry.id);
        unsafe {
            ticket.write(entry.id);
        }
        return match &entry.result {
            Some(Ok(image)) => {
                unsafe {
                    out.write(image_result(image.clone()));
                }
                state.stats.cache_hits += 1;
                0
            }
            Some(Err(message)) => {
                let mut end = message.len().min(255);
                while !message.is_char_boundary(end) {
                    end -= 1;
                }
                unsafe {
                    (&mut (*out).error)[..end].copy_from_slice(&message.as_bytes()[..end]);
                }
                1
            }
            None => 2,
        };
    }
    if state.queue.len() >= MAX_QUEUE {
        return 2;
    }
    if state.entries.len() >= MAX_ENTRIES {
        let candidate = state
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| e.users.is_empty() && e.result.is_some())
            .min_by_key(|(_, e)| e.used)
            .map(|(i, _)| i);
        let Some(index) = candidate else {
            return 2;
        };
        remove(&mut state, index);
    }
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    state.entries.push(Entry {
        id,
        key,
        users: HashSet::from([context.id]),
        used: tick,
        result: None,
    });
    state.queue.push_back(id);
    state.stats.queued = state.queue.len() as u64;
    context.current.insert(id);
    unsafe {
        ticket.write(id);
    }
    context.service.core.ready.notify_one();
    2
}

fn remove(state: &mut State, index: usize) {
    if let Some(Ok(image)) = &state.entries[index].result {
        state.stats.cpu_bytes -= image.pixels.len() as u64;
    }
    state.entries.swap_remove(index);
}
fn work(core: Arc<Core>, worker_path: String) {
    let mut process: Option<crate::process::Process> = None;
    loop {
        let (id, key) = {
            let mut state = core.state.lock().unwrap();
            while state.queue.is_empty() && !state.stop {
                state = core.ready.wait(state).unwrap();
            }
            if state.stop {
                return;
            }
            let id = state.queue.pop_front().unwrap();
            state.stats.queued = state.queue.len() as u64;
            let Some(index) = state.entries.iter().position(|e| e.id == id) else {
                continue;
            };
            if state.entries[index].users.is_empty() {
                remove(&mut state, index);
                state.stats.canceled += 1;
                continue;
            }
            (id, state.entries[index].key.clone())
        };
        let start = Instant::now();
        let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
            if cfg!(test) {
                return render(&key.source, &key.options());
            }
            if process.is_none() {
                process = Some(crate::process::Process::start(&worker_path)?);
            }
            let result = process
                .as_mut()
                .unwrap()
                .render(&key.source, &key.options(), || {
                    core.stopping.load(Ordering::Relaxed)
                        || !core
                            .state
                            .lock()
                            .unwrap()
                            .entries
                            .iter()
                            .any(|e| e.id == id && !e.users.is_empty())
                });
            if result.is_err() {
                process = None;
            }
            result
        }))
        .unwrap_or_else(|_| Err("RaTeX panicked".into()))
        .map(Arc::new);
        let notifications = {
            let mut state = core.state.lock().unwrap();
            state.stats.renders += 1;
            state.stats.render_ns += start.elapsed().as_nanos().min(u64::MAX as u128) as u64;
            if result
                .as_ref()
                .err()
                .is_some_and(|e| e == "math worker canceled")
            {
                if let Some(index) = state.entries.iter().position(|e| e.id == id) {
                    if state.entries[index].users.is_empty() {
                        remove(&mut state, index);
                    } else {
                        state.queue.push_front(id);
                        core.ready.notify_one();
                    }
                }
                state.stats.canceled += 1;
                continue;
            }
            let mut result = result;
            if let Ok(image) = &result {
                let size = image.pixels.len() as u64;
                while state.stats.cpu_bytes + size > MAX_BYTES as u64 {
                    let candidate = state
                        .entries
                        .iter()
                        .enumerate()
                        .filter(|(_, e)| e.id != id && e.users.is_empty() && e.result.is_some())
                        .min_by_key(|(_, e)| e.used)
                        .map(|(i, _)| i);
                    if let Some(index) = candidate {
                        remove(&mut state, index);
                    } else {
                        break;
                    }
                }
                if state.stats.cpu_bytes + size > MAX_BYTES as u64 {
                    result = Err("CPU cache budget exhausted".into());
                } else {
                    state.stats.cpu_bytes += size;
                }
            }
            if result.is_err() {
                state.stats.failures += 1;
            }
            if let Some(entry) = state.entries.iter_mut().find(|e| e.id == id) {
                entry.result = Some(result);
            }
            state.contexts.values().cloned().collect::<Vec<_>>()
        };
        for notifier in notifications {
            notifier.notify();
        }
    }
}
/// # Safety
/// Context and stats must point to valid, aligned storage.
#[no_mangle]
pub unsafe extern "C" fn ghosttex_math_stats(context: *mut Context, stats: *mut Stats) {
    if context.is_null() || stats.is_null() {
        return;
    }
    let context = unsafe { &*context };
    unsafe {
        stats.write(context.service.core.state.lock().unwrap().stats);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn worker_shares_cache_rejects_stale_work_and_releases_contexts() {
        let context =
            unsafe { ghosttex_math_context_create(None, std::ptr::null_mut(), b"".as_ptr(), 0) };
        assert!(!context.is_null());
        let options = crate::tests::options(true);
        let source = r"\frac{a}{b}";
        let mut first = 0;
        for _ in 0..200 {
            let mut result = ResultImage::default();
            let mut ticket = 0;
            unsafe {
                ghosttex_math_frame_begin(context);
            }
            let status = unsafe {
                ghosttex_math_request(
                    context,
                    source.as_ptr(),
                    source.len(),
                    &options,
                    &mut result,
                    &mut ticket,
                )
            };
            unsafe {
                ghosttex_math_frame_finish(context);
            }
            if first == 0 {
                first = ticket;
            } else {
                assert_eq!(ticket, first);
            }
            if status == 0 {
                unsafe {
                    ghosttex_math_free(&mut result);
                }
                break;
            }
            assert_eq!(status, 2);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let mut stats = Stats::default();
        unsafe {
            ghosttex_math_stats(context, &mut stats);
        }
        assert_eq!(stats.renders, 1);
        assert!(stats.cache_hits > 0 && stats.cpu_bytes > 0);
        unsafe {
            ghosttex_math_context_destroy(context);
        }
        assert!(SERVICE.lock().unwrap().upgrade().is_none());
    }
}
