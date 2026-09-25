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

#[derive(Clone)]
pub struct NeovimHandler<S: BridgeSink> {
    pub sink: S,
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
