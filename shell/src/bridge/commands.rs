//! Commands from the shell to Neovim.
//!
//! Serial commands (keys, mouse) must reach Neovim in the order they happened; parallel
//! commands (resize, focus, quit) can run concurrently. Consecutive wheel scrolls with the
//! same target are merged so a fast wheel does not flood the RPC channel. Ported from
//! Neovide's src/bridge/ui_commands.rs (MIT, LICENSE-NEOVIDE).

use anyhow::{Context, Result};
use nvim_rs::{call_args, rpc::model::IntoVal, Neovim};
use rmpv::Value;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};

use super::session::NeovimWriter;

#[derive(Clone, Debug)]
pub enum SerialCommand {
    Keyboard(String),
    /// Text committed by an IME, already escaped for `nvim_input`.
    ImeCommit(String),
    MouseButton { button: String, action: String, grid_id: u64, position: (u32, u32), modifier_string: String },
    Scroll { direction: String, grid_id: u64, position: (u32, u32), count: u32, modifier_string: String },
    Drag { button: String, grid_id: u64, position: (u32, u32), modifier_string: String },
}

#[derive(PartialEq, Eq)]
struct ScrollMergeKey<'a> {
    direction: &'a str,
    grid_id: u64,
    position: (u32, u32),
    modifier_string: &'a str,
}

impl SerialCommand {
    fn scroll_merge_key(&self) -> Option<ScrollMergeKey<'_>> {
        match self {
            Self::Scroll { direction, grid_id, position, modifier_string, .. } => {
                Some(ScrollMergeKey { direction, grid_id: *grid_id, position: *position, modifier_string })
            }
            _ => None,
        }
    }

    /// Absorb `next` into this scroll if they target the same place; otherwise hand it back.
    fn try_merge_scroll(&mut self, next: Self) -> Option<Self> {
        let can_merge = matches!((self.scroll_merge_key(), next.scroll_merge_key()), (Some(a), Some(b)) if a == b);
        if !can_merge {
            return Some(next);
        }
        match (self, next) {
            (Self::Scroll { count, .. }, Self::Scroll { count: next_count, .. }) => {
                *count = count.saturating_add(next_count);
                None
            }
            (_, other) => Some(other),
        }
    }

    async fn execute(self, nvim: &Neovim<NeovimWriter>) {
        let result: Result<()> = match self {
            SerialCommand::Keyboard(input) | SerialCommand::ImeCommit(input) => {
                log::trace!("input: {input}");
                nvim.input(&input).await.map(|_| ()).context("nvim_input failed")
            }
            SerialCommand::MouseButton { button, action, grid_id, position: (x, y), modifier_string } => nvim
                .input_mouse(&button, &action, &modifier_string, grid_id as i64, y as i64, x as i64)
                .await
                .context("nvim_input_mouse failed"),
            SerialCommand::Scroll { direction, grid_id, position: (x, y), count, modifier_string } => {
                let mut r = Ok(());
                for _ in 0..count {
                    r = nvim
                        .input_mouse("wheel", &direction, &modifier_string, grid_id as i64, y as i64, x as i64)
                        .await
                        .context("mouse scroll failed");
                    if r.is_err() {
                        break;
                    }
                }
                r
            }
            SerialCommand::Drag { button, grid_id, position: (x, y), modifier_string } => nvim
                .input_mouse(&button, "drag", &modifier_string, grid_id as i64, y as i64, x as i64)
                .await
                .context("mouse drag failed"),
        };
        if let Err(error) = result {
            log::error!("{error:?}");
        }
    }
}

#[derive(Clone, Debug)]
pub enum ParallelCommand {
    /// Ask Neovim to quit; `confirm` uses `:confirm qa` so unsaved buffers prompt.
    Quit { confirm: bool },
    Resize { width: u64, height: u64 },
    FocusLost,
    FocusGained,
    /// Run an Ex command (the shell's own actions, e.g. opening a file from the explorer).
    Command(String),
    /// Run a Lua chunk with arguments; the result is dropped.
    ExecLua { code: String, args: Vec<Value> },
    /// Paste text at the cursor through `nvim_paste`.
    Paste(String),
}

impl ParallelCommand {
    async fn execute(self, nvim: &Neovim<NeovimWriter>) {
        let result: Result<()> = match self {
            ParallelCommand::Quit { confirm } => {
                let code = if confirm { "vim.cmd('confirm qa')" } else { "vim.cmd('qa!')" };
                // Neovim exits before answering, so errors here are expected and ignored.
                let _ = nvim.exec_lua(code, vec![]).await;
                Ok(())
            }
            ParallelCommand::Resize { width, height } => {
                nvim.ui_try_resize(width.max(10) as i64, height.max(3) as i64).await.context("resize failed")
            }
            ParallelCommand::FocusLost => nvim.ui_set_focus(false).await.context("focus lost failed"),
            ParallelCommand::FocusGained => nvim.ui_set_focus(true).await.context("focus gained failed"),
            ParallelCommand::Command(cmd) => nvim.command(&cmd).await.context("command failed"),
            ParallelCommand::ExecLua { code, args } => nvim.exec_lua(&code, args).await.map(|_| ()).context("exec_lua failed"),
            ParallelCommand::Paste(text) => nvim
                .call("nvim_paste", call_args![text, true, -1i64])
                .await
                .map(|_| ())
                .context("paste failed"),
        };
        if let Err(error) = result {
            log::error!("{error:?}");
        }
    }
}

#[derive(Debug, Clone)]
pub enum UiCommand {
    Serial(SerialCommand),
    Parallel(ParallelCommand),
}

impl From<SerialCommand> for UiCommand {
    fn from(c: SerialCommand) -> Self {
        UiCommand::Serial(c)
    }
}

impl From<ParallelCommand> for UiCommand {
    fn from(c: ParallelCommand) -> Self {
        UiCommand::Parallel(c)
    }
}

/// Start the two tasks that drain the command channel: one keeps serial commands in order
/// (merging scrolls), the other spawns each parallel command on its own.
pub fn start_command_handler(nvim: Neovim<NeovimWriter>, mut rx: UnboundedReceiver<UiCommand>) {
    let (serial_tx, mut serial_rx) = unbounded_channel::<SerialCommand>();

    let nvim_parallel = nvim.clone();
    tokio::spawn(async move {
        while let Some(command) = rx.recv().await {
            match command {
                UiCommand::Serial(c) => {
                    let _ = serial_tx.send(c);
                }
                UiCommand::Parallel(c) => {
                    let nvim = nvim_parallel.clone();
                    tokio::spawn(async move { c.execute(&nvim).await });
                }
            }
        }
        log::info!("ui command receiver finished");
    });

    tokio::spawn(async move {
        let mut pending: Option<SerialCommand> = None;
        loop {
            let mut command = match pending.take() {
                Some(c) => c,
                None => match serial_rx.recv().await {
                    Some(c) => c,
                    None => break,
                },
            };
            if matches!(command, SerialCommand::Scroll { .. }) {
                while let Ok(next) = serial_rx.try_recv() {
                    if let Some(other) = command.try_merge_scroll(next) {
                        pending = Some(other);
                        break;
                    }
                }
            }
            command.execute(&nvim).await;
        }
        log::info!("serial command receiver finished");
    });
}

/// The shell's handle for sending commands. Cheap to clone.
#[derive(Clone)]
pub struct CommandSender(pub UnboundedSender<UiCommand>);

impl CommandSender {
    pub fn send(&self, command: impl Into<UiCommand>) {
        if self.0.send(command.into()).is_err() {
            log::warn!("command dropped: Neovim is gone");
        }
    }
}
