//! nvs-ide: the native window around `nvim --embed`.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use nvs_shell::app::{App, AppConfig, ScriptAction};
use nvs_shell::bridge::BridgeConfig;
use nvs_shell::font::FontOptions;

const USAGE: &str = "nvs-ide [options] [files...] [-- nvim args...]

  --nvim-bin <path>     Neovim executable (default: nvim on PATH)
  --config <appname>    NVIM_APPNAME to run (default: nvs-ide; 'default' = your own config)
  --renderer <name>     auto | vulkan | dx12 | gl
  --font <guifont>      e.g. \"BigBlueTerm437 Nerd Font Mono:h9\" (overrides 'guifont')
  --size <WxH>          initial window size in logical pixels (default 1280x800)
  --startuptime         print startup timings to stderr after the first frame
  --tabline             take over the tab line (ext_tabline)
  --screenshot <png>    save the window to a PNG (1500 ms after the first flush) and quit
  --screenshot-after <ms>
  --quit-after <ms>     quit this long after the first flush
  --send <keys>         feed keys (nvim_input notation) 400 ms after the first flush; repeatable
  --panel               start with the bottom panel open
  --palette             start with the command palette open
  --view <name>         start with a sidebar view focused (explorer|search|git|…)
  --search <text>       start a workspace search for <text>
  --screen <name>       open a screen (welcome|settings|plugins|learn); settings:Keys picks a category
  --do <ms>:<what>:<arg> scripted input after the first flush; repeatable, in order:
                        click:x,y  rclick:x,y  type:text  key:ctrl+shift+p  send:<Esc>
  --help";

fn parse_args() -> Result<AppConfig, String> {
    let mut bridge = BridgeConfig::default();
    let mut backends = wgpu::Backends::PRIMARY;
    let mut font = None;
    let mut window_size = None;
    let mut report_startup = false;
    let mut screenshot: Option<std::path::PathBuf> = None;
    let mut screenshot_after = std::time::Duration::from_millis(1500);
    let mut quit_after = None;
    let mut sends = Vec::new();
    let mut open_panel = false;
    let mut open_palette = false;
    let mut start_view = None;
    let mut start_search = None;
    let mut start_screen = None;
    let mut start_screen_part: Option<String> = None;
    let mut script = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => return Err(USAGE.into()),
            "--nvim-bin" => bridge.nvim_bin = args.next().ok_or("--nvim-bin needs a path")?,
            "--config" => {
                let name = args.next().ok_or("--config needs a name")?;
                bridge.app_name = if name == "default" { None } else { Some(name) };
            }
            "--renderer" => {
                backends = match args.next().as_deref() {
                    Some("auto") | None => wgpu::Backends::PRIMARY,
                    Some("vulkan") => wgpu::Backends::VULKAN,
                    Some("dx12") => wgpu::Backends::DX12,
                    Some("gl") => wgpu::Backends::GL,
                    Some(other) => return Err(format!("unknown renderer {other}")),
                }
            }
            "--font" => {
                let spec = args.next().ok_or("--font needs a guifont value")?;
                font = Some(FontOptions::parse(&spec).ok_or_else(|| format!("cannot parse font {spec}"))?);
            }
            "--size" => {
                let spec = args.next().ok_or("--size needs WxH")?;
                let (w, h) = spec.split_once('x').ok_or("--size needs WxH")?;
                window_size = Some((w.parse().map_err(|_| "bad width")?, h.parse().map_err(|_| "bad height")?));
            }
            "--startuptime" => report_startup = true,
            "--tabline" => bridge.ext_tabline = true,
            "--screenshot" => screenshot = Some(args.next().ok_or("--screenshot needs a path")?.into()),
            "--screenshot-after" => {
                let ms: u64 = args.next().ok_or("--screenshot-after needs ms")?.parse().map_err(|_| "bad ms")?;
                screenshot_after = std::time::Duration::from_millis(ms);
            }
            "--quit-after" => {
                let ms: u64 = args.next().ok_or("--quit-after needs ms")?.parse().map_err(|_| "bad ms")?;
                quit_after = Some(std::time::Duration::from_millis(ms));
            }
            "--send" => sends.push(args.next().ok_or("--send needs keys")?),
            "--panel" => open_panel = true,
            "--palette" => open_palette = true,
            "--view" => {
                start_view = Some(match args.next().as_deref() {
                    Some("explorer") => nvs_shell::workbench::View::Explorer,
                    Some("search") => nvs_shell::workbench::View::Search,
                    Some("git") => nvs_shell::workbench::View::Git,
                    Some("plugins") => nvs_shell::workbench::View::Plugins,
                    Some("ask") => nvs_shell::workbench::View::Ask,
                    Some("learn") => nvs_shell::workbench::View::Learn,
                    Some("debug") => nvs_shell::workbench::View::Debug,
                    other => return Err(format!("unknown view {other:?}")),
                })
            }
            "--search" => start_search = Some(args.next().ok_or("--search needs text")?),
            "--do" => script.push(ScriptAction::parse(&args.next().ok_or("--do needs <ms>:<action>:<arg>")?)?),
            "--screen" => {
                // settings:Keys opens that category; plugins:extras opens that tab.
                let spec = args.next().ok_or("--screen needs a name")?;
                let (name, part) = spec.split_once(':').map(|(a, b)| (a.to_string(), Some(b.to_string()))).unwrap_or((spec.clone(), None));
                start_screen = Some(match name.as_str() {
                    "welcome" => nvs_shell::workbench::Screen::Welcome,
                    "settings" => nvs_shell::workbench::Screen::Settings,
                    "plugins" => nvs_shell::workbench::Screen::Plugins,
                    "learn" => nvs_shell::workbench::Screen::Learn,
                    other => return Err(format!("unknown screen {other}")),
                });
                start_screen_part = part;
            }
            "--" => {
                bridge.nvim_args.extend(args.by_ref());
            }
            other if other.starts_with('-') => return Err(format!("unknown option {other}\n\n{USAGE}")),
            file => bridge.files.push(file.to_string()),
        }
    }
    Ok(AppConfig {
        bridge,
        backends,
        font,
        window_size,
        report_startup,
        title: "nvs.ide".into(),
        screenshot: screenshot.map(|p| (p, screenshot_after)),
        quit_after,
        sends,
        open_panel,
        open_palette,
        start_view,
        start_search,
        start_screen,
        start_screen_part,
        script,
    })
}

#[cfg(windows)]
fn attach_console() {
    // A windows-subsystem exe has no console; borrow the parent's so --startuptime and logs show.
    unsafe {
        windows_sys::Win32::System::Console::AttachConsole(windows_sys::Win32::System::Console::ATTACH_PARENT_PROCESS);
    }
}

fn main() {
    nvs_shell::timing::init();
    #[cfg(windows)]
    attach_console();
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("nvs_shell=info,nvs_ide=info,wgpu_core=warn,wgpu_hal=warn")).init();
    let config = match parse_args() {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(if msg == USAGE { 0 } else { 2 });
        }
    };
    match App::run(config) {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("nvs.ide: {e:#}");
            std::process::exit(1);
        }
    }
}
