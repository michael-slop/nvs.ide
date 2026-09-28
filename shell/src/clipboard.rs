//! The system clipboard for Neovim's `+` and `*` registers, served by the window on Linux.
//!
//! Neovim reaches the clipboard by running a tool: wl-copy, xclip or xsel. A Linux desktop
//! with none of them installed gets "clipboard: No clipboard tool", silently, so Ctrl+C and
//! Ctrl+V do nothing at Stages 1 to 3. The window already holds a connection to the display,
//! so it answers instead: bridge/init.lua points `g:clipboard` at the `nvs.get_clipboard`
//! and `nvs.set_clipboard` requests (bridge/handler.rs). On Wayland the clipboard goes
//! through the window's own display connection, which needs no data-control protocol, so it
//! works on GNOME; on X11 it opens its own connections. Windows and macOS keep Neovim's own
//! providers (clip and PowerShell, pbcopy), which need nothing installed.
//!
//! Ported from Neovide's src/clipboard.rs and src/bridge/clipboard.rs (MIT, LICENSE-NEOVIDE).

use std::sync::{Arc, Mutex};

use rmpv::Value;
use winit::event_loop::ActiveEventLoop;

#[cfg(target_os = "linux")]
type Provider = Box<dyn copypasta::ClipboardProvider>;

/// The `+` clipboard and the `*` primary selection.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
struct Providers {
    #[cfg(target_os = "linux")]
    clipboard: Provider,
    #[cfg(target_os = "linux")]
    selection: Option<Provider>,
}

/// Shared between the window (which opens and closes it) and the bridge's request handler.
#[derive(Clone)]
pub struct SharedClipboard(Arc<Mutex<Option<Providers>>>);

impl std::fmt::Debug for SharedClipboard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SharedClipboard")
    }
}

impl SharedClipboard {
    /// The display's clipboard, on Linux. `None` on Windows and macOS, and on a Linux display
    /// that offers none, where Neovim's own providers stay in charge.
    pub fn open(event_loop: &ActiveEventLoop) -> Option<Self> {
        let providers = open_providers(event_loop)?;
        Some(Self(Arc::new(Mutex::new(Some(providers)))))
    }

    /// Drop the providers while the display is still connected: the Wayland one keeps a
    /// worker thread on the event loop's display, which must not outlive it.
    pub fn close(&self) {
        if let Ok(mut inner) = self.0.lock() {
            inner.take();
        }
    }

    /// `nvs.get_clipboard`: `[lines, regtype]` for Neovim's paste.
    pub fn get(&self, register: &str) -> Result<Value, String> {
        let text = self.with(register, |p| get_contents(p))?;
        Ok(paste_value(&text))
    }

    /// `nvs.set_clipboard`: Neovim's yanked lines.
    pub fn set(&self, lines: &Value, register: &str) -> Result<(), String> {
        let text = join_lines(lines)?;
        self.with(register, |p| set_contents(p, text))
    }

    fn with<T>(&self, register: &str, f: impl FnOnce(&mut Providers) -> Result<T, String>) -> Result<T, String> {
        let mut inner = self.0.lock().map_err(|e| format!("clipboard lock: {e}"))?;
        let providers = inner.as_mut().ok_or_else(|| "the clipboard is closed".to_string())?;
        let _ = register;
        #[cfg(target_os = "linux")]
        if register == "*" {
            if let Some(selection) = providers.selection.take() {
                // The primary selection has its own provider; lend it as the clipboard.
                let mut lent = Providers { clipboard: selection, selection: None };
                let result = f(&mut lent);
                providers.selection = Some(lent.clipboard);
                return result;
            }
        }
        f(providers)
    }
}

#[cfg(target_os = "linux")]
fn get_contents(p: &mut Providers) -> Result<String, String> {
    p.clipboard.get_contents().map_err(|e| e.to_string())
}

#[cfg(target_os = "linux")]
fn set_contents(p: &mut Providers, text: String) -> Result<(), String> {
    p.clipboard.set_contents(text).map_err(|e| e.to_string())
}

#[cfg(not(target_os = "linux"))]
fn get_contents(_: &mut Providers) -> Result<String, String> {
    Err("the window serves the clipboard on Linux only".into())
}

#[cfg(not(target_os = "linux"))]
fn set_contents(_: &mut Providers, _: String) -> Result<(), String> {
    Err("the window serves the clipboard on Linux only".into())
}

#[cfg(target_os = "linux")]
fn open_providers(event_loop: &ActiveEventLoop) -> Option<Providers> {
    use copypasta::x11_clipboard::{Primary, X11ClipboardContext};
    use copypasta::{wayland_clipboard, ClipboardContext};
    use winit::raw_window_handle::{HasDisplayHandle, RawDisplayHandle};

    let handle = match event_loop.display_handle() {
        Ok(h) => h.as_raw(),
        Err(e) => {
            log::warn!("no display handle for the clipboard: {e}");
            return None;
        }
    };
    match handle {
        RawDisplayHandle::Wayland(h) => {
            // SAFETY: the display is the event loop's, and SharedClipboard::close drops these
            // (and their worker thread) in `exiting`, before the event loop lets it go.
            let (selection, clipboard) = unsafe { wayland_clipboard::create_clipboards_from_external(h.display.as_ptr()) };
            log::info!("clipboard: Wayland, through the window's display connection");
            Some(Providers { clipboard: Box::new(clipboard), selection: Some(Box::new(selection)) })
        }
        RawDisplayHandle::Xlib(_) | RawDisplayHandle::Xcb(_) => {
            let clipboard = match ClipboardContext::new() {
                Ok(c) => c,
                Err(e) => {
                    log::warn!("X11 clipboard unavailable: {e}");
                    return None;
                }
            };
            let selection = X11ClipboardContext::<Primary>::new().map_err(|e| log::warn!("X11 primary selection unavailable: {e}")).ok();
            log::info!("clipboard: X11");
            Some(Providers { clipboard: Box::new(clipboard), selection: selection.map(|s| Box::new(s) as Provider) })
        }
        other => {
            log::warn!("no clipboard for this display ({other:?}); Neovim's own providers stay in charge");
            None
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn open_providers(_: &ActiveEventLoop) -> Option<Providers> {
    None
}

/// Clipboard text as Neovim's paste wants it: `[lines, regtype]`. Text ending in a newline
/// pastes linewise ("V"), anything else characterwise ("v"), as Neovide does.
pub fn paste_value(text: &str) -> Value {
    let text = text.replace('\r', "");
    let regtype = if text.ends_with('\n') { "V" } else { "v" };
    let lines: Vec<Value> = text.split('\n').map(Value::from).collect();
    Value::from(vec![Value::from(lines), Value::from(regtype)])
}

/// Neovim's yanked lines (an array of strings) as clipboard text.
pub fn join_lines(lines: &Value) -> Result<String, String> {
    let lines = lines.as_array().ok_or_else(|| "the clipboard expects a list of lines".to_string())?;
    Ok(lines.iter().filter_map(|l| l.as_str()).map(|s| s.replace('\r', "")).collect::<Vec<_>>().join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paste_is_linewise_only_after_a_trailing_newline() {
        assert_eq!(paste_value("one"), Value::from(vec![Value::from(vec![Value::from("one")]), Value::from("v")]));
        let v = paste_value("a\r\nb\n");
        assert_eq!(v, Value::from(vec![Value::from(vec![Value::from("a"), Value::from("b"), Value::from("")]), Value::from("V")]));
    }

    #[test]
    fn yanked_lines_join_with_newlines() {
        let lines = Value::from(vec![Value::from("a"), Value::from("b\r")]);
        assert_eq!(join_lines(&lines).unwrap(), "a\nb");
        assert!(join_lines(&Value::from("not a list")).is_err());
    }
}
