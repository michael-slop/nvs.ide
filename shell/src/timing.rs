//! Startup timing. The design's budgets are measured here, by the shell itself, and
//! printed with `--startuptime`.

use std::sync::{Mutex, OnceLock};
use std::time::Instant;

static START: OnceLock<Instant> = OnceLock::new();
static MARKS: Mutex<Vec<(&'static str, f64)>> = Mutex::new(Vec::new());

/// Call once, first thing in main.
pub fn init() {
    START.get_or_init(Instant::now);
}

pub fn elapsed_ms() -> f64 {
    START.get().map(|s| s.elapsed().as_secs_f64() * 1000.0).unwrap_or(0.0)
}

/// Record a named point in time since process start.
pub fn mark(name: &'static str) {
    let ms = elapsed_ms();
    log::info!("startup: {name} at {ms:.1} ms");
    if let Ok(mut m) = MARKS.lock() {
        m.push((name, ms));
    }
}

pub fn report() -> String {
    let m = MARKS.lock().map(|m| m.clone()).unwrap_or_default();
    let mut out = String::from("nvs.ide startup (ms since process start)\n");
    for (name, ms) in m {
        out.push_str(&format!("{ms:9.1}  {name}\n"));
    }
    out
}
