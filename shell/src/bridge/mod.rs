//! The bridge: one embedded Neovim, the RPC connection to it, and the command channel back.
//!
//! Attach sequence (order matters, it is Neovide's):
//! 1. spawn `nvim --embed` with NVIM_APPNAME set so runtime/ is the config;
//! 2. `nvim_get_api_info` for the channel id and version, refuse anything below 0.10;
//! 3. `nvim_set_var("nvs_shell", true)`, `nvim_set_client_info("nvs-ide", ..)`;
//! 4. run INIT_LUA (channel id into `g:nvs_channel`, termguicolors, VimLeavePre -> nvs.quit);
//! 5. `nvim_ui_attach` with ext_linegrid + ext_multigrid (+ ext_tabline when asked), which
//!    lets `--embed` continue startup and load the user config.

pub mod api_info;
pub mod commands;
pub mod events;
pub mod handler;
pub mod session;

use std::{path::PathBuf, time::Duration};

use anyhow::{bail, Context, Result};
use nvim_rs::{Neovim, UiAttachOptions, Value};
use tokio::{process::Command, runtime::Runtime, select, sync::mpsc::unbounded_channel, time::timeout};

pub use api_info::{ApiInfo, ApiVersion};
pub use commands::{CommandSender, ParallelCommand, SerialCommand, UiCommand};
pub use events::*;
pub use session::{NeovimSession, NeovimWriter};

use handler::NeovimHandler;

const NEOVIM_REQUIRED_VERSION: (u64, u64, u64) = (0, 10, 0);
const INIT_LUA: &str = include_str!("init.lua");

/// Where events from Neovim go. Implemented by the app (editor thread + event loop) and by tests.
pub trait BridgeSink: Send + Sync + Clone + 'static {
    /// A batch of parsed redraw events, in order. Ends with `Flush` when Neovim is done drawing.
    fn redraw(&self, events: Vec<RedrawEvent>);
    /// A workbench notification from runtime/lua/nvs/bridge.lua.
    fn nvs(&self, event: String, payload: Value);
    /// Neovim is about to exit with this code (from VimLeavePre).
    fn quit_requested(&self, code: i32);
    /// The Neovim process and its RPC stream are gone.
    fn exited(&self);
}

#[derive(Clone, Debug)]
pub struct BridgeConfig {
    pub nvim_bin: String,
    pub nvim_args: Vec<String>,
    pub files: Vec<String>,
    pub cwd: Option<PathBuf>,
    /// Value for NVIM_APPNAME; `None` leaves the environment alone.
    pub app_name: Option<String>,
    pub grid: (u32, u32),
    pub ext_tabline: bool,
    pub client_version: (u64, u64, u64),
}

impl Default for BridgeConfig {
    fn default() -> Self {
        Self {
            nvim_bin: "nvim".into(),
            nvim_args: vec![],
            files: vec![],
            cwd: None,
            app_name: Some("nvs-ide".into()),
            grid: (100, 40),
            ext_tabline: false,
            client_version: (0, 1, 0),
        }
    }
}

pub struct Bridge {
    runtime: Option<Runtime>,
    pub nvim: Neovim<NeovimWriter>,
    pub commands: CommandSender,
    pub info: ApiInfo,
}

/// Where the nvs.ide runtime (the Neovim config folder) lives: `NVS_RUNTIME`, or `runtime/`
/// next to the exe (an install), or three levels up from `shell/target/<profile>/` (the repo).
pub fn find_runtime() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("NVS_RUNTIME") {
        let p = PathBuf::from(p);
        if p.join("init.lua").is_file() {
            return Some(p);
        }
    }
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    for candidate in [dir.join("runtime"), dir.join("../../../runtime")] {
        if candidate.join("init.lua").is_file() {
            return candidate.canonicalize().ok().map(strip_verbatim);
        }
    }
    None
}

fn strip_verbatim(p: PathBuf) -> PathBuf {
    let s = p.to_string_lossy();
    match s.strip_prefix(r"\\?\") {
        Some(rest) => PathBuf::from(rest),
        None => p,
    }
}

/// Neovim's config folder for an app name: `$XDG_CONFIG_HOME/<app>`, else
/// `%LOCALAPPDATA%\<app>` on Windows or `~/.config/<app>` elsewhere.
fn config_dir_for(app: &str) -> Option<PathBuf> {
    if let Some(x) = std::env::var_os("XDG_CONFIG_HOME") {
        return Some(PathBuf::from(x).join(app));
    }
    if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA").map(|l| PathBuf::from(l).join(app))
    } else {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config").join(app))
    }
}

/// First run: link the app's config folder to the runtime so `nvim --embed` finds LazyVim
/// and the nvs layer. A folder that already exists is left alone, whatever it holds.
fn ensure_config_link(app: &str) {
    let Some(config) = config_dir_for(app) else { return };
    if config.exists() || std::fs::symlink_metadata(&config).is_ok() {
        return;
    }
    let Some(runtime) = find_runtime() else {
        log::warn!("{} does not exist and the nvs.ide runtime was not found next to the exe; Neovim starts with no config", config.display());
        return;
    };
    if let Some(parent) = config.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    #[cfg(windows)]
    let ok = {
        // A junction needs no privilege, unlike a symlink.
        use std::os::windows::process::CommandExt;
        let output = std::process::Command::new("cmd").args(["/C", "mklink", "/J"]).arg(&config).arg(&runtime).creation_flags(0x0800_0000).output();
        matches!(output, Ok(o) if o.status.success())
    };
    #[cfg(not(windows))]
    let ok = std::os::unix::fs::symlink(&runtime, &config).is_ok();
    if ok {
        log::info!("linked {} -> {}", config.display(), runtime.display());
    } else {
        log::warn!("could not link {} -> {}", config.display(), runtime.display());
    }
}

fn build_command(config: &BridgeConfig) -> Command {
    if let Some(app) = &config.app_name {
        ensure_config_link(app);
    }
    let mut cmd = Command::new(&config.nvim_bin);
    cmd.args(&config.nvim_args);
    if !config.nvim_args.iter().any(|a| a == "--embed") {
        cmd.arg("--embed");
    }
    cmd.args(&config.files);
    if let Some(app) = &config.app_name {
        cmd.env("NVIM_APPNAME", app);
    }
    if let Some(cwd) = &config.cwd {
        cmd.current_dir(cwd);
    }
    #[cfg(windows)]
    {
        // No console window for the child.
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

async fn attach<S: BridgeSink>(config: &BridgeConfig, sink: S) -> Result<(NeovimSession, ApiInfo, CommandSender)> {
    let handler = NeovimHandler { sink };
    let session = NeovimSession::spawn(build_command(config), handler)
        .await
        .context("could not start Neovim; is nvim on PATH?")?;
    let nvim = session.neovim.clone();

    let raw = nvim.get_api_info().await.context("nvim_get_api_info failed")?;
    let info = api_info::parse_api_info(&raw)?;
    log::info!("neovim {} on channel {}", info.version, info.channel);
    let (major, minor, patch) = NEOVIM_REQUIRED_VERSION;
    if !info.version.at_least(major, minor, patch) {
        bail!("nvs.ide needs Neovim {major}.{minor}.{patch} or newer, found {}", info.version);
    }

    nvim.set_var("nvs_shell", Value::from(true)).await.context("set_var failed")?;
    let (vmaj, vmin, vpat) = config.client_version;
    nvim.set_client_info(
        "nvs-ide",
        vec![
            (Value::from("major"), Value::from(vmaj)),
            (Value::from("minor"), Value::from(vmin)),
            (Value::from("patch"), Value::from(vpat)),
        ],
        "ui",
        vec![],
        vec![(Value::from("website"), Value::from("https://github.com/michael-slop/nvs.ide"))],
    )
    .await
    .context("set_client_info failed")?;
    nvim.exec_lua(INIT_LUA, vec![Value::from(info.channel)]).await.context("shell init.lua failed")?;

    let (tx, rx) = unbounded_channel();
    commands::start_command_handler(nvim.clone(), rx);

    let mut options = UiAttachOptions::new();
    options.set_linegrid_external(true);
    options.set_multigrid_external(true);
    options.set_rgb(true);
    if config.ext_tabline {
        options.set_tabline_external(true);
    }
    nvim.ui_attach(config.grid.0 as i64, config.grid.1 as i64, &options).await.context("nvim_ui_attach failed")?;
    log::info!("ui attached at {}x{}", config.grid.0, config.grid.1);

    Ok((session, info, CommandSender(tx)))
}

/// Wait for the session to end: either the RPC stream closes or the process exits.
async fn run_session<S: BridgeSink>(mut session: NeovimSession, sink: S) {
    #[cfg(windows)]
    let exit = session.process.take().map(|mut child| tokio::task::spawn_blocking(move || child.wait()));
    #[cfg(not(windows))]
    let exit = session.process.take().map(|mut child| async move { child.wait().await });

    if let Some(exit) = exit {
        select! {
            _ = &mut session.io_handle => {}
            _ = exit => {
                // Neovim can exit before its stream is drained (neovim/neovim#26743); give it a moment.
                if timeout(Duration::from_millis(500), &mut session.io_handle).await.is_err() {
                    log::info!("nvim exited but its stream never closed; giving up on it");
                }
            }
        }
    } else {
        let _ = session.io_handle.await;
    }
    if let Some(stderr) = &mut session.stderr_task {
        let _ = timeout(Duration::from_millis(500), stderr).await;
    }
    sink.exited();
}

impl Bridge {
    /// Spawn Neovim and attach. Blocks until the UI is attached (or fails).
    pub fn start<S: BridgeSink>(config: BridgeConfig, sink: S) -> Result<Bridge> {
        let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
        let (session, info, commands) = runtime.block_on(attach(&config, sink.clone()))?;
        let nvim = session.neovim.clone();
        runtime.spawn(run_session(session, sink));
        Ok(Bridge { runtime: Some(runtime), nvim, commands, info })
    }

    pub fn send(&self, command: impl Into<UiCommand>) {
        self.commands.send(command);
    }

    /// Run a future on the bridge's runtime and wait for it (for tests and one-off calls).
    pub fn block_on<F: std::future::Future>(&self, f: F) -> F::Output {
        self.runtime.as_ref().expect("bridge runtime").block_on(f)
    }

    pub fn shutdown(mut self, wait: Duration) {
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_timeout(wait);
        }
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_timeout(Duration::from_millis(500));
        }
    }
}
