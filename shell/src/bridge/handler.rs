//! The nvim-rs `Handler`: everything Neovim sends us.
//!
//! `redraw` notifications are parsed and handed to the sink (the editor thread). `nvs`
//! notifications come from runtime/lua/nvs/bridge.lua and carry workbench state (mode,
//! buffers, diagnostics, settings). The `nvs.quit` request is how Neovim tells us its exit
//! code from VimLeavePre. Modelled on Neovide's src/bridge/handler.rs (MIT, LICENSE-NEOVIDE).

use async_trait::async_trait;
use nvim_rs::{Handler, Neovim};
use rmpv::Value;

use super::{events::parse_redraw_event, session::NeovimWriter, BridgeSink, RedrawEvent};
use crate::clipboard::SharedClipboard;

#[derive(Clone)]
pub struct NeovimHandler<S: BridgeSink> {
    pub sink: S,
    /// Answers `nvs.get_clipboard` / `nvs.set_clipboard` when the window serves the clipboard.
    pub clipboard: Option<SharedClipboard>,
}

fn register(args: &[Value], i: usize) -> String {
    args.get(i).and_then(Value::as_str).unwrap_or("+").to_string()
}

#[async_trait]
impl<S: BridgeSink> Handler for NeovimHandler<S> {
    type Writer = NeovimWriter;

    async fn handle_request(&self, name: String, args: Vec<Value>, _neovim: Neovim<Self::Writer>) -> Result<Value, Value> {
        log::trace!("nvim request: {name}");
        match name.as_str() {
            "nvs.quit" => {
                let code = args.first().and_then(Value::as_i64).unwrap_or(0);
                self.sink.quit_requested(code as i32);
                Ok(Value::Nil)
            }
            "nvs.ping" => Ok(Value::from("pong")),
            // Clipboard calls can wait on the display server, so they run off the async
            // workers. Neovim blocks on the reply either way.
            "nvs.get_clipboard" | "nvs.set_clipboard" => {
                let Some(clipboard) = self.clipboard.clone() else {
                    return Err(Value::from("the window is not serving the clipboard"));
                };
                let result = tokio::task::spawn_blocking(move || {
                    if name == "nvs.get_clipboard" {
                        clipboard.get(&register(&args, 0))
                    } else {
                        let lines = args.first().cloned().unwrap_or(Value::Nil);
                        clipboard.set(&lines, &register(&args, 1)).map(|()| Value::Nil)
                    }
                })
                .await
                .map_err(|e| Value::from(e.to_string()))?;
                result.map_err(|e| {
                    log::warn!("clipboard: {e}");
                    Value::from(e)
                })
            }
            _ => Err(Value::from(format!("unknown request {name}"))),
        }
    }

    async fn handle_notify(&self, name: String, args: Vec<Value>, _neovim: Neovim<Self::Writer>) {
        match name.as_str() {
            "redraw" => {
                let mut events: Vec<RedrawEvent> = Vec::with_capacity(args.len());
                for batch in args {
                    match parse_redraw_event(batch) {
                        Ok(parsed) => events.extend(parsed),
                        Err(err) => log::error!("could not parse redraw event: {err}"),
                    }
                }
                if !events.is_empty() {
                    self.sink.redraw(events);
                }
            }
            "nvs" => {
                // ["nvs", event_name, payload]
                let mut it = args.into_iter();
                let event = it.next().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
                let payload = it.next().unwrap_or(Value::Nil);
                self.sink.nvs(event, payload);
            }
            other => log::trace!("unhandled nvim notification {other}"),
        }
    }
}
