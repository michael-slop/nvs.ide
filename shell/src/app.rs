//! The winit application: window, GPU, bridge, editor thread and workbench wired together.
//!
//! Threads: winit's main thread renders and handles input; the bridge's tokio runtime talks
//! to Neovim; the editor thread turns redraw events into frames and posts them to the event
//! loop as user events. The shell never blocks on Neovim.
//!
//! Input routing: pointer events over the grid go to Neovim, over the chrome to the
//! workbench. Keys go to the workbench while a chrome area has focus, else to Neovim, after
//! the shell's own shortcuts (Ctrl+B, Ctrl+`, Ctrl+Shift+E/F/G/M) have had their chance.

use std::{
    sync::{mpsc::Sender, Arc},
    time::{Duration, Instant},
};

use anyhow::Result;
use rmpv::Value;
use winit::{
    application::ApplicationHandler,
    dpi::{LogicalSize, PhysicalSize},
    event::{ElementState, MouseButton, MouseScrollDelta, StartCause, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy},
    keyboard::{Key, NamedKey},
    window::{Icon, Window, WindowAttributes, WindowId},
};

use crate::bridge::{Bridge, BridgeConfig, BridgeSink, EditorMode, ParallelCommand, RedrawEvent, SerialCommand};
use crate::color::Rgba;
use crate::editor::{start_editor_thread, EditorNotice, Frame, FrameSink};
use crate::font::{shaper::Shaper, FontOptions, FontStack};
use crate::input::{KeyOutput, KeyboardManager, MouseManager, WindowRegion};
use crate::renderer::{
    blink::{BlinkAction, BlinkStatus},
    paint_frame, Gpu, Painter,
};
use crate::timing;
use crate::ui::{theme, KeyPress, Rect, UiEvent, UiInput};
use crate::workbench::{state::decode, tasks, Action, Diagnostic, Focus, ImportReport, NvimState, PanelTab, PluginsModel, Screen, SettingsModel, TaskResult, View, Workbench};

const ICON_PNG: &[u8] = include_bytes!("../../assets/nvs.ide.png");

#[derive(Debug)]
pub enum UserEvent {
    Frame(Arc<Frame>),
    Notice(EditorNotice),
    Nvs(String, Value),
    Task(TaskResult),
    QuitRequested(i32),
    NvimExited,
}

/// Bridge events go to the editor thread (redraws) or straight to the event loop.
#[derive(Clone)]
struct AppSink {
    editor: Sender<Vec<RedrawEvent>>,
    proxy: EventLoopProxy<UserEvent>,
}

impl BridgeSink for AppSink {
    fn redraw(&self, events: Vec<RedrawEvent>) {
        let _ = self.editor.send(events);
    }
    fn nvs(&self, event: String, payload: Value) {
        let _ = self.proxy.send_event(UserEvent::Nvs(event, payload));
    }
    fn quit_requested(&self, code: i32) {
        let _ = self.proxy.send_event(UserEvent::QuitRequested(code));
    }
    fn exited(&self) {
        let _ = self.proxy.send_event(UserEvent::NvimExited);
    }
}

struct EditorToApp {
    proxy: EventLoopProxy<UserEvent>,
}

impl FrameSink for EditorToApp {
    fn frame(&mut self, frame: Arc<Frame>) {
        let _ = self.proxy.send_event(UserEvent::Frame(frame));
    }
    fn notice(&mut self, notice: EditorNotice) {
        let _ = self.proxy.send_event(UserEvent::Notice(notice));
    }
}

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub bridge: BridgeConfig,
    pub backends: wgpu::Backends,
    pub font: Option<FontOptions>,
    pub window_size: Option<(u32, u32)>,
    pub report_startup: bool,
    pub title: String,
    /// Save a PNG of the window this long after the first flush, then quit unless
    /// `quit_after` says otherwise.
    pub screenshot: Option<(std::path::PathBuf, Duration)>,
    /// Quit this long after the first flush (automated runs).
    pub quit_after: Option<Duration>,
    /// Key sequences to feed Neovim 400 ms after the first flush (automated runs).
    pub sends: Vec<String>,
    /// Start with the bottom panel open / the palette open (screenshots).
    pub open_panel: bool,
    pub open_palette: bool,
    /// Start with this sidebar view focused (screenshots).
    pub start_view: Option<View>,
    /// Start a workspace search with this text (screenshots).
    pub start_search: Option<String>,
    /// Open a native screen at start (screenshots), and a category or tab within it.
    pub start_screen: Option<Screen>,
    pub start_screen_part: Option<String>,
    /// Scripted input against the chrome, each this long after the first flush (the --do flag).
    pub script: Vec<(Duration, ScriptAction)>,
}

/// One scripted input step: what a person would do with the mouse or keyboard on the chrome.
#[derive(Clone, Debug)]
pub enum ScriptAction {
    /// Click at window pixels.
    Click { x: f32, y: f32, right: bool },
    /// Type text into whatever chrome widget has the keyboard (or Neovim, if none does).
    Type(String),
    /// One key, with optional ctrl/shift/alt: "Enter", "ctrl+shift+p", "Escape", "Down".
    Key(String),
    /// Feed Neovim keys in nvim_input notation.
    Send(String),
}

impl ScriptAction {
    /// "800:click:20,64" -> (800 ms, Click); "1200:type:vim.g" ; "1500:key:ctrl+shift+p" ; "2000:send:<Esc>"
    pub fn parse(spec: &str) -> Result<(Duration, ScriptAction), String> {
        let mut parts = spec.splitn(3, ':');
        let ms: u64 = parts.next().and_then(|s| s.parse().ok()).ok_or_else(|| format!("--do {spec}: needs <ms>:<action>:<arg>"))?;
        let action = parts.next().unwrap_or("");
        let arg = parts.next().unwrap_or("").to_string();
        let act = match action {
            "click" | "rclick" => {
                let (x, y) = arg.split_once(',').ok_or_else(|| format!("--do {spec}: click needs x,y"))?;
                ScriptAction::Click { x: x.trim().parse().map_err(|_| "bad x")?, y: y.trim().parse().map_err(|_| "bad y")?, right: action == "rclick" }
            }
            "type" => ScriptAction::Type(arg),
            "key" => ScriptAction::Key(arg),
            "send" => ScriptAction::Send(arg),
            other => return Err(format!("--do {spec}: unknown action {other}")),
        };
        Ok((Duration::from_millis(ms), act))
    }
}

pub struct App {
    config: AppConfig,
    proxy: EventLoopProxy<UserEvent>,
    window: Option<Arc<Window>>,
    gpu: Option<Gpu>,
    fonts: Option<FontStack>,
    shaper: Shaper,
    bridge: Option<Bridge>,
    frame: Option<Arc<Frame>>,
    keyboard: KeyboardManager,
    mouse: MouseManager,
    blink: BlinkStatus,
    regions: Vec<WindowRegion>,
    grid_size: (u32, u32),
    workbench: Workbench,
    ui_input: UiInput,
    shown: bool,
    exit_code: i32,
    exiting: bool,
    frames_rendered: u64,
    pending_font: Option<String>,
    first_flush_at: Option<Instant>,
    screenshot_done: bool,
    sends_done: bool,
    script_done: usize,
    next_wake: Option<Instant>,
}

impl App {
    pub fn run(config: AppConfig) -> Result<i32> {
        let event_loop = EventLoop::<UserEvent>::with_user_event().build()?;
        event_loop.set_control_flow(ControlFlow::Wait);
        let proxy = event_loop.create_proxy();
        let mut app = App {
            config,
            proxy,
            window: None,
            gpu: None,
            fonts: None,
            shaper: Shaper::new(),
            bridge: None,
            frame: None,
            keyboard: KeyboardManager::new(),
            mouse: MouseManager::new(),
            blink: BlinkStatus::new(),
            regions: Vec::new(),
            grid_size: (0, 0),
            workbench: Workbench::new(),
            ui_input: UiInput::default(),
            shown: false,
            exit_code: 0,
            exiting: false,
            frames_rendered: 0,
            pending_font: None,
            first_flush_at: None,
            screenshot_done: false,
            sends_done: false,
            script_done: 0,
            next_wake: None,
        };
        event_loop.run_app(&mut app)?;
        Ok(app.exit_code)
    }

    fn icon() -> Option<Icon> {
        let image = image::load_from_memory(ICON_PNG).ok()?.into_rgba8();
        let (w, h) = image.dimensions();
        Icon::from_rgba(image.into_raw(), w, h).ok()
    }

    fn cell(&self) -> (f32, f32) {
        self.fonts.as_ref().map(|f| (f.metrics().width, f.metrics().height)).unwrap_or((8.0, 12.0))
    }

    /// Grid size that fits the editor area; at least 10x3 as Neovim requires.
    fn grid_for(&self, area: Rect) -> (u32, u32) {
        let (cw, ch) = self.cell();
        let cols = ((area.w / cw).floor() as u32).max(10);
        let rows = ((area.h / ch).floor() as u32).max(3);
        (cols, rows)
    }

    fn relayout(&mut self) -> Rect {
        let size = self.window.as_ref().map(|w| w.inner_size()).unwrap_or(PhysicalSize::new(1280, 800));
        let layout = self.workbench.compute_layout(size.width as f32, size.height as f32);
        layout.grid
    }

    fn sync_grid_size(&mut self) {
        let grid_rect = self.relayout();
        let grid = self.grid_for(grid_rect);
        if grid != self.grid_size {
            self.grid_size = grid;
            if let Some(bridge) = &self.bridge {
                bridge.send(ParallelCommand::Resize { width: grid.0 as u64, height: grid.1 as u64 });
            }
        }
    }

    fn start_bridge(&mut self, editor_tx: Sender<Vec<RedrawEvent>>) -> Result<()> {
        let mut config = self.config.bridge.clone();
        config.grid = self.grid_size;
        let sink = AppSink { editor: editor_tx, proxy: self.proxy.clone() };
        let bridge = Bridge::start(config, sink)?;
        timing::mark("nvim attached");
        self.workbench.log(format!("neovim {} attached on channel {}", bridge.info.version, bridge.info.channel));
        self.bridge = Some(bridge);
        Ok(())
    }

    fn apply_font(&mut self, guifont: &str) {
        let Some(fonts) = self.fonts.as_mut() else { return };
        match FontOptions::parse(guifont) {
            Some(options) if options != fonts.options => {
                if let Err(e) = fonts.set_options(options) {
                    log::error!("font change failed: {e}");
                }
                self.after_font_change();
            }
            _ => {}
        }
    }

    fn after_font_change(&mut self) {
        self.shaper.clear();
        if let Some(gpu) = self.gpu.as_mut() {
            let device = gpu.device().clone();
            gpu.atlas.clear(&device);
        }
        self.sync_grid_size();
        self.request_redraw();
    }

    fn request_redraw(&self) {
        if let Some(w) = &self.window {
            w.request_redraw();
        }
    }

    fn send(&self, command: impl Into<crate::bridge::UiCommand>) {
        if let Some(bridge) = &self.bridge {
            bridge.send(command);
        }
    }

    fn apply_actions(&mut self, actions: Vec<Action>) {
        let mut relayout = false;
        for action in actions {
            match action {
                Action::Command(cmd) => self.send(ParallelCommand::Command(cmd)),
                Action::Lua(code, args) => self.send(ParallelCommand::ExecLua { code, args }),
                Action::Keys(keys) => self.send(SerialCommand::Keyboard(keys)),
                Action::FocusGrid => self.workbench.focus = Focus::Grid,
                Action::Spawn(task) => {
                    let proxy = self.proxy.clone();
                    std::thread::Builder::new()
                        .name("nvs-task".into())
                        .spawn(move || {
                            let result = tasks::run(task);
                            let _ = proxy.send_event(UserEvent::Task(result));
                        })
                        .ok();
                }
            }
            relayout = true;
        }
        if relayout {
            self.sync_grid_size();
            self.request_redraw();
        }
    }

    fn render(&mut self) {
        let grid_rect = self.relayout();
        let (Some(gpu), Some(fonts), Some(window)) = (self.gpu.as_mut(), self.fonts.as_mut(), self.window.as_ref()) else { return };
        let blink_visible = self.blink.visible();
        let frame = self.frame.clone();
        let mut quads = Vec::new();
        let mut actions = Vec::new();
        let mut layout = None;
        // The atlas may grow mid-frame; when it does, every quad built so far is stale.
        for attempt in 0..4 {
            let mut painter = Painter::new(gpu, fonts, &mut self.shaper);
            let result = (|| -> Result<(), crate::renderer::AtlasFull> {
                // The grid first, then the chrome over it (the palette and screens overlap it).
                if let (Some(frame), true) = (&frame, self.workbench.grid_visible()) {
                    let bg = frame.default_style.background(&frame.default_style.colors);
                    painter.rect(grid_rect.x, grid_rect.y, grid_rect.w, grid_rect.h, bg);
                    layout = Some(paint_frame(&mut painter, frame, (grid_rect.x, grid_rect.y), blink_visible && self.workbench.keyboard_owner() == Focus::Grid)?);
                } else {
                    painter.rect(grid_rect.x, grid_rect.y, grid_rect.w, grid_rect.h, theme::CRYPT);
                }
                actions = self.workbench.draw(&mut painter, &self.ui_input)?;
                Ok(())
            })();
            match result {
                Ok(()) => {
                    quads = painter.quads;
                    break;
                }
                Err(_) if attempt < 3 => continue,
                Err(_) => log::error!("atlas kept overflowing; frame skipped"),
            }
        }
        self.ui_input.events.clear();
        if let Some(layout) = layout {
            self.regions = layout.regions;
        }
        let capture_now = match (&self.config.screenshot, self.first_flush_at) {
            (Some((_, delay)), Some(t0)) => !self.screenshot_done && t0.elapsed() >= *delay,
            _ => false,
        };
        if capture_now {
            let (ok, captured) = gpu.render_and_capture(&quads, theme::CRYPT);
            if !ok {
                window.request_redraw();
                return;
            }
            self.screenshot_done = true;
            if let (Some((path, _)), Some(capture)) = (&self.config.screenshot, captured) {
                match capture.save_png(path) {
                    Ok(()) => log::info!("screenshot {}x{} saved to {}", capture.width, capture.height, path.display()),
                    Err(e) => log::error!("screenshot failed: {e}"),
                }
            } else {
                log::error!("this surface cannot be captured");
            }
            if self.config.quit_after.is_none() {
                self.send(ParallelCommand::Quit { confirm: false });
            }
        } else if !gpu.render(&quads, theme::CRYPT) {
            window.request_redraw();
            return;
        }
        self.frames_rendered += 1;
        if !self.shown {
            self.shown = true;
            timing::mark("first frame presented");
            if self.config.report_startup {
                eprintln!("{}", timing::report());
            }
        }
        self.apply_actions(actions);
    }

    /// Timers the shell waits on: cursor blink, the screenshot delay, the automated quit.
    fn schedule_wakeups(&mut self, event_loop: &ActiveEventLoop) {
        let mut next: Option<Instant> = None;
        let mut consider = |t: Instant| next = Some(next.map_or(t, |n| n.min(t)));
        if let Some(frame) = &self.frame {
            match self.blink.update(&frame.cursor) {
                BlinkAction::Immediately => self.request_redraw(),
                BlinkAction::Deadline(t) => consider(t),
                BlinkAction::Wait => {}
            }
        }
        if let Some(t0) = self.first_flush_at {
            if !self.sends_done && !self.config.sends.is_empty() {
                let due = t0 + Duration::from_millis(400);
                if Instant::now() >= due {
                    self.sends_done = true;
                    for keys in self.config.sends.clone() {
                        self.send(SerialCommand::Keyboard(keys));
                    }
                } else {
                    consider(due);
                }
            }
            if let Some((_, delay)) = &self.config.screenshot {
                if !self.screenshot_done {
                    consider(t0 + *delay);
                }
            }
            // Scripted input, in order, each at its own delay.
            while let Some((delay, action)) = self.config.script.get(self.script_done).cloned() {
                let due = t0 + delay;
                if Instant::now() < due {
                    consider(due);
                    break;
                }
                self.script_done += 1;
                self.run_script_action(action);
            }
            if let Some(delay) = self.config.quit_after {
                let due = t0 + delay;
                if Instant::now() >= due && !self.exiting {
                    self.send(ParallelCommand::Quit { confirm: false });
                    self.exiting = true;
                } else {
                    consider(due);
                }
            }
        }
        if self.exiting {
            consider(Instant::now() + Duration::from_secs(2));
        }
        self.next_wake = next;
        event_loop.set_control_flow(match next {
            Some(t) => ControlFlow::WaitUntil(t),
            None => ControlFlow::Wait,
        });
    }

    /// One scripted input step, through the same paths as real input where the chrome is
    /// concerned (the Neovim grid gets keys through nvim_input instead of winit events).
    fn run_script_action(&mut self, action: ScriptAction) {
        use winit::keyboard::ModifiersState;
        match action {
            ScriptAction::Click { x, y, right } => {
                self.ui_input.mouse = (x, y);
                self.ui_input.events.push(UiEvent::PointerMove { x, y });
                if self.workbench.is_chrome_at(x, y) {
                    self.ui_input.events.push(UiEvent::PointerDown { x, y, right });
                    self.ui_input.events.push(UiEvent::PointerUp { x, y });
                } else {
                    self.workbench.focus = Focus::Grid;
                    self.workbench.close_palette();
                    log::info!("script: click at {x},{y} is on the grid; only chrome clicks are scripted");
                }
            }
            ScriptAction::Type(text) => {
                if self.workbench.keyboard_owner() != Focus::Grid {
                    for c in text.chars() {
                        let s = c.to_string();
                        self.ui_input.events.push(UiEvent::Key(KeyPress { key: Key::Character(s.as_str().into()), modifiers: ModifiersState::empty(), text: Some(s) }));
                    }
                } else {
                    self.send(SerialCommand::Keyboard(text.replace('<', "<lt>")));
                }
            }
            ScriptAction::Key(spec) => {
                let mut mods = ModifiersState::empty();
                let mut name = "";
                for part in spec.split('+') {
                    match part.to_lowercase().as_str() {
                        "ctrl" => mods |= ModifiersState::CONTROL,
                        "shift" => mods |= ModifiersState::SHIFT,
                        "alt" => mods |= ModifiersState::ALT,
                        _ => name = part,
                    }
                }
                let key = match name {
                    "Enter" | "Return" => Key::Named(NamedKey::Enter),
                    "Escape" | "Esc" => Key::Named(NamedKey::Escape),
                    "Tab" => Key::Named(NamedKey::Tab),
                    "Space" => Key::Named(NamedKey::Space),
                    "Backspace" => Key::Named(NamedKey::Backspace),
                    "Down" => Key::Named(NamedKey::ArrowDown),
                    "Up" => Key::Named(NamedKey::ArrowUp),
                    "Left" => Key::Named(NamedKey::ArrowLeft),
                    "Right" => Key::Named(NamedKey::ArrowRight),
                    "PageDown" => Key::Named(NamedKey::PageDown),
                    "PageUp" => Key::Named(NamedKey::PageUp),
                    "F1" => Key::Named(NamedKey::F1),
                    other => Key::Character(other.into()),
                };
                if mods.control_key() && self.shell_shortcut(&key, true, mods.shift_key()) {
                    self.sync_grid_size();
                } else if self.workbench.keyboard_owner() != Focus::Grid {
                    if key == Key::Named(NamedKey::Escape) && self.workbench.palette.is_none() {
                        self.workbench.focus = Focus::Grid;
                    }
                    let text = match &key {
                        Key::Character(c) if !mods.control_key() && !mods.alt_key() => Some(c.to_string()),
                        Key::Named(NamedKey::Space) => Some(" ".into()),
                        _ => None,
                    };
                    self.ui_input.events.push(UiEvent::Key(KeyPress { key, modifiers: mods, text }));
                } else {
                    // Neovim owns the keyboard: send it in nvim_input notation.
                    let base = match name {
                        "Enter" | "Return" => "CR".to_string(),
                        "Escape" => "Esc".to_string(),
                        other => other.to_string(),
                    };
                    let mut s = String::new();
                    if mods.control_key() {
                        s.push_str("C-");
                    }
                    if mods.shift_key() {
                        s.push_str("S-");
                    }
                    if mods.alt_key() {
                        s.push_str("A-");
                    }
                    let keys = if s.is_empty() && base.chars().count() == 1 { base } else { format!("<{s}{base}>") };
                    self.send(SerialCommand::Keyboard(keys));
                }
            }
            ScriptAction::Send(keys) => self.send(SerialCommand::Keyboard(keys)),
        }
        self.request_redraw();
    }

    /// The shell's own keys. Returns true when handled.
    fn shell_shortcut(&mut self, key: &Key, ctrl: bool, shift: bool) -> bool {
        if !ctrl {
            return false;
        }
        let stage = self.workbench.nvim.stage;
        let mut actions = Vec::new();
        let handled = match key {
            Key::Character(c) => match (c.to_lowercase().as_str(), shift) {
                ("b", false) if stage <= 3 => {
                    self.workbench.toggle_sidebar(None);
                    true
                }
                ("`", false) => {
                    self.workbench.toggle_panel(None);
                    true
                }
                (",", false) => {
                    self.workbench.open_screen(Screen::Settings);
                    true
                }
                ("p", true) => {
                    actions = self.workbench.open_palette("");
                    true
                }
                ("e", true) => {
                    actions = self.workbench.focus_view(View::Explorer);
                    true
                }
                ("f", true) => {
                    actions = self.workbench.focus_view(View::Search);
                    true
                }
                ("g", true) => {
                    actions = self.workbench.focus_view(View::Git);
                    true
                }
                ("x", true) => {
                    self.workbench.open_screen(Screen::Plugins);
                    true
                }
                ("m", true) => {
                    self.workbench.toggle_panel(Some(PanelTab::Problems));
                    if self.workbench.panel_open {
                        self.workbench.focus = Focus::Panel;
                    }
                    true
                }
                _ => false,
            },
            _ => false,
        };
        if handled {
            self.apply_actions(actions);
        }
        handled
    }

    fn handle_nvs(&mut self, event: &str, payload: Value) {
        match event {
            "state" => match decode::<NvimState>(payload) {
                Ok(state) => {
                    self.workbench.nvim = state;
                    self.workbench.state_arrived();
                }
                Err(e) => log::warn!("bad nvs state: {e}"),
            },
            "diagnostics" => match decode::<Vec<Diagnostic>>(payload) {
                Ok(d) => self.workbench.diagnostics = d,
                Err(e) => log::warn!("bad nvs diagnostics: {e}"),
            },
            "settings" => match decode::<SettingsModel>(payload) {
                Ok(m) => {
                    self.workbench.set_settings(m);
                    self.sync_grid_size();
                }
                Err(e) => log::warn!("bad nvs settings: {e}"),
            },
            "plugins" => match decode::<PluginsModel>(payload) {
                Ok(m) => self.workbench.set_plugins(m),
                Err(e) => log::warn!("bad nvs plugins: {e}"),
            },
            "settings_report" => match decode::<ImportReport>(payload) {
                Ok(r) => self.workbench.set_import_report(r),
                Err(e) => log::warn!("bad nvs settings_report: {e}"),
            },
            // Neovim asks the window to show one of its screens (:NvsSettings, :NvsWelcome).
            "open" => {
                let what = payload.as_str().unwrap_or("").to_string();
                match what.as_str() {
                    "settings" => self.workbench.open_screen(Screen::Settings),
                    "plugins" => self.workbench.open_screen(Screen::Plugins),
                    "learn" => self.workbench.open_screen(Screen::Learn),
                    "welcome" => self.workbench.open_screen(Screen::Welcome),
                    other => log::warn!("nvs open: unknown screen {other}"),
                }
                self.sync_grid_size();
            }
            other => log::debug!("nvs event {other}"),
        }
        self.request_redraw();
    }
}

impl ApplicationHandler<UserEvent> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let (w, h) = self.config.window_size.unwrap_or((1280, 800));
        let attributes = WindowAttributes::default()
            .with_title(&self.config.title)
            .with_inner_size(LogicalSize::new(w as f64, h as f64))
            .with_min_inner_size(LogicalSize::new(400.0, 200.0))
            .with_visible(false)
            .with_theme(Some(winit::window::Theme::Dark))
            .with_window_icon(Self::icon());
        let window = match event_loop.create_window(attributes) {
            Ok(w) => Arc::new(w),
            Err(e) => {
                log::error!("window creation failed: {e}");
                event_loop.exit();
                return;
            }
        };
        timing::mark("window created");
        let scale = window.scale_factor() as f32;

        let fonts = match FontStack::new(self.config.font.clone().unwrap_or_default(), scale) {
            Ok(f) => f,
            Err(e) => {
                log::error!("no usable font: {e}");
                event_loop.exit();
                return;
            }
        };
        self.fonts = Some(fonts);
        timing::mark("fonts loaded");

        match Gpu::new(window.clone(), self.config.backends) {
            Ok(gpu) => {
                log::info!("gpu ready: {} via {:?}", gpu.adapter_name, gpu.backend);
                self.workbench.log(format!("renderer: {} via {:?}", gpu.adapter_name, gpu.backend));
                self.gpu = Some(gpu);
            }
            Err(e) => {
                log::error!("GPU init failed: {e:#}");
                event_loop.exit();
                return;
            }
        }
        timing::mark("gpu ready");
        self.window = Some(window.clone());
        // Show the window now, already painted: a hidden window's surface reports itself
        // occluded, so waiting for the first Neovim frame before showing never presents.
        self.render();
        window.set_visible(true);
        timing::mark("window visible");

        if self.config.open_panel {
            self.workbench.toggle_panel(Some(PanelTab::Problems));
        }
        if self.config.open_palette {
            let actions = self.workbench.open_palette("");
            self.apply_actions(actions);
        }
        if let Some(view) = self.config.start_view {
            let actions = self.workbench.focus_view(view);
            self.apply_actions(actions);
        }
        if let Some(screen) = self.config.start_screen {
            self.workbench.open_screen(screen);
            self.workbench.start_part = self.config.start_screen_part.clone();
        }
        if let Some(text) = self.config.start_search.clone() {
            let actions = self.workbench.focus_view(View::Search);
            self.apply_actions(actions);
            self.workbench.search.query.set(&text);
            self.workbench.search.editing = false;
            self.workbench.search.searching = true;
            self.workbench.search.generation = 1;
            let cwd = self.workbench.cwd();
            let args = self.workbench.search_args();
            self.apply_actions(vec![Action::Spawn(tasks::Task::Search { generation: 1, cwd, query: text, args })]);
        }
        let grid_rect = self.relayout();
        self.grid_size = self.grid_for(grid_rect);
        let editor_tx = start_editor_thread(EditorToApp { proxy: self.proxy.clone() });
        if let Err(e) = self.start_bridge(editor_tx) {
            log::error!("{e:#}");
            eprintln!("nvs.ide: {e:#}");
            event_loop.exit();
            return;
        }
        if let Some(font) = self.pending_font.take() {
            self.apply_font(&font);
        }
    }

    fn new_events(&mut self, event_loop: &ActiveEventLoop, cause: StartCause) {
        if let StartCause::ResumeTimeReached { .. } = cause {
            if self.exiting && self.frame.is_some() && self.config.quit_after.is_none() && self.screenshot_done {
                // Quit was sent; if Neovim never exits (a prompt we cannot see), leave anyway.
                event_loop.exit();
                return;
            }
            self.request_redraw();
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        match event {
            UserEvent::Frame(frame) => {
                if self.frame.is_none() {
                    timing::mark("first flush");
                    self.first_flush_at = Some(Instant::now());
                }
                self.frame = Some(frame);
                if !self.shown || self.frames_rendered < 2 {
                    // Draw the first frames right away rather than waiting for a redraw event.
                    self.render();
                    self.schedule_wakeups(event_loop);
                } else {
                    self.request_redraw();
                }
            }
            UserEvent::Notice(notice) => match notice {
                EditorNotice::Title(title) => {
                    if let Some(w) = &self.window {
                        w.set_title(if title.is_empty() { &self.config.title } else { &title });
                    }
                }
                EditorNotice::FontChanged(font) => {
                    if self.config.font.is_some() {
                        // A --font on the command line wins over 'guifont'.
                        return;
                    }
                    if self.fonts.is_some() {
                        self.apply_font(&font);
                    } else {
                        self.pending_font = Some(font);
                    }
                }
                EditorNotice::LineSpaceChanged(ls) => {
                    if let Some(f) = self.fonts.as_mut() {
                        f.set_linespace(ls);
                    }
                    self.after_font_change();
                }
                EditorNotice::MouseEnabled(on) => self.mouse.enabled = on,
                EditorNotice::ExtOption { name, enabled } => log::debug!("neovim option {name} = {enabled}"),
                EditorNotice::ModeChanged(mode) => {
                    if let EditorMode::Unknown(m) = &mode {
                        log::debug!("mode {m}");
                    }
                }
            },
            UserEvent::Nvs(event, payload) => self.handle_nvs(&event, payload),
            UserEvent::Task(result) => {
                let actions = self.workbench.task_done(result);
                self.apply_actions(actions);
                self.request_redraw();
            }
            UserEvent::QuitRequested(code) => {
                self.exit_code = code;
                self.exiting = true;
                self.schedule_wakeups(event_loop);
            }
            UserEvent::NvimExited => {
                log::info!("neovim exited with {}", self.exit_code);
                event_loop.exit();
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match &event {
            WindowEvent::CloseRequested => {
                if self.bridge.is_some() {
                    self.send(ParallelCommand::Quit { confirm: true });
                } else {
                    event_loop.exit();
                }
            }
            WindowEvent::Resized(size) => {
                if let Some(gpu) = self.gpu.as_mut() {
                    gpu.resize(size.width, size.height);
                }
                self.sync_grid_size();
                self.request_redraw();
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                if let Some(f) = self.fonts.as_mut() {
                    f.set_scale(*scale_factor as f32);
                }
                self.after_font_change();
            }
            WindowEvent::RedrawRequested => {
                self.render();
                self.schedule_wakeups(event_loop);
            }
            WindowEvent::Focused(focused) => {
                self.send(if *focused { ParallelCommand::FocusGained } else { ParallelCommand::FocusLost });
            }
            WindowEvent::ModifiersChanged(_) | WindowEvent::Ime(_) => {
                if let KeyOutput::Input(text) = self.keyboard.handle_event(&event) {
                    self.send(SerialCommand::Keyboard(text));
                }
            }
            WindowEvent::KeyboardInput { event: key_event, .. } => {
                let mods = self.keyboard.modifiers().state();
                if key_event.state == ElementState::Pressed && self.shell_shortcut(&key_event.logical_key, mods.control_key(), mods.shift_key()) {
                    self.sync_grid_size();
                    self.request_redraw();
                    return;
                }
                if self.workbench.keyboard_owner() != Focus::Grid {
                    if key_event.state == ElementState::Pressed {
                        if key_event.logical_key == Key::Named(NamedKey::Escape) && self.workbench.palette.is_none() {
                            self.workbench.focus = Focus::Grid;
                        }
                        self.ui_input.events.push(UiEvent::Key(KeyPress {
                            key: key_event.logical_key.clone(),
                            modifiers: mods,
                            text: key_event.text.as_ref().map(|t| t.to_string()),
                        }));
                        self.request_redraw();
                    }
                    return;
                }
                if let KeyOutput::Input(text) = self.keyboard.handle_event(&event) {
                    self.send(SerialCommand::Keyboard(text));
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                let (x, y) = (position.x as f32, position.y as f32);
                self.ui_input.mouse = (x, y);
                self.ui_input.events.push(UiEvent::PointerMove { x, y });
                if !self.workbench.is_chrome_at(x, y) {
                    if let Some(bridge) = &self.bridge {
                        let modifiers = self.keyboard.format_modifier_string("", true);
                        let cell = self.cell();
                        self.mouse.handle_event(&event, &self.regions, cell, &modifiers, &bridge.commands);
                    }
                }
                self.request_redraw();
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let (x, y) = self.ui_input.mouse;
                let over_chrome = self.workbench.is_chrome_at(x, y);
                let down = *state == ElementState::Pressed;
                if *button == MouseButton::Left {
                    self.ui_input.mouse_down = down;
                }
                if over_chrome || !down {
                    self.ui_input.events.push(if down { UiEvent::PointerDown { x, y, right: *button == MouseButton::Right } } else { UiEvent::PointerUp { x, y } });
                }
                if !over_chrome {
                    if down {
                        self.workbench.focus = Focus::Grid;
                        self.workbench.close_palette();
                    }
                    if let Some(bridge) = &self.bridge {
                        let modifiers = self.keyboard.format_modifier_string("", true);
                        let cell = self.cell();
                        self.mouse.handle_event(&event, &self.regions, cell, &modifiers, &bridge.commands);
                    }
                }
                self.request_redraw();
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let (x, y) = self.ui_input.mouse;
                if self.workbench.is_chrome_at(x, y) {
                    let lines = match delta {
                        MouseScrollDelta::LineDelta(_, y) => *y,
                        MouseScrollDelta::PixelDelta(p) => p.y as f32 / self.cell().1,
                    };
                    self.ui_input.events.push(UiEvent::Scroll { x, y, lines });
                } else if let Some(bridge) = &self.bridge {
                    let modifiers = self.keyboard.format_modifier_string("", true);
                    let cell = self.cell();
                    self.mouse.handle_event(&event, &self.regions, cell, &modifiers, &bridge.commands);
                }
                self.request_redraw();
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        if self.exiting && self.next_wake.is_none() {
            // Neovim said it is leaving; if the process lingers, do not keep the window forever.
            event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_secs(2)));
        }
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(bridge) = self.bridge.take() {
            bridge.shutdown(Duration::from_millis(500));
        }
    }
}

#[allow(dead_code)]
fn _unused(_: Rgba) {}
