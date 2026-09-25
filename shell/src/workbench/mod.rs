//! The workbench: activity bar, sidebar, tab strip, bottom panel, status bar and palette,
//! drawn around Neovim's grid. Owns the chrome state and turns clicks and keys into actions
//! for Neovim or background tasks.

pub mod explorer;
pub mod git;
pub mod palette;
pub mod plugins;
pub mod search;
pub mod settings;
pub mod state;
pub mod tasks;

use std::path::PathBuf;

use winit::keyboard::NamedKey;

use crate::renderer::{AtlasFull, Painter};
use crate::ui::widgets::{self, ListState, Row, Tab, TextResponse};
use crate::ui::{self, theme, Rect, UiEvent, UiInput};

pub use palette::{Palette, PaletteCommand, PaletteItem, PaletteSource};
pub use plugins::PluginsModel;
pub use settings::{ImportReport, SettingsModel};
pub use state::{Diagnostic, NvimState};
pub use tasks::{Task, TaskResult};

pub const ACTIVITY_W: f32 = 44.0;
pub const TABS_H: f32 = 28.0;
pub const STATUS_H: f32 = 22.0;
const SIDEBAR_MIN: f32 = 160.0;
const PANEL_MIN: f32 = 60.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum View {
    Explorer,
    Search,
    Git,
    Debug,
    Plugins,
    Ask,
    Learn,
}

impl View {
    pub const ALL: [View; 7] = [View::Explorer, View::Search, View::Git, View::Debug, View::Plugins, View::Ask, View::Learn];

    pub fn icon(self) -> &'static str {
        match self {
            View::Explorer => "explorer",
            View::Search => "search",
            View::Git => "git",
            View::Debug => "debug",
            View::Plugins => "plugins",
            View::Ask => "ask",
            View::Learn => "learn",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            View::Explorer => "Explorer",
            View::Search => "Search",
            View::Git => "Source control",
            View::Debug => "Run and debug",
            View::Plugins => "Plugins",
            View::Ask => "Ask",
            View::Learn => "Learn",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PanelTab {
    Problems,
    Output,
    Terminal,
}

/// Native screens that open as tabs and take the editor area.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Screen {
    Welcome,
    Settings,
    Plugins,
    Learn,
}

impl Screen {
    pub fn title(self) -> &'static str {
        match self {
            Screen::Welcome => "Welcome",
            Screen::Settings => "Settings",
            Screen::Plugins => "Plugins",
            Screen::Learn => "Learn",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Focus {
    Grid,
    Sidebar,
    Panel,
    Palette,
    Screen,
}

/// What the workbench wants done after a pass.
#[derive(Clone, Debug)]
pub enum Action {
    /// Run an Ex command.
    Command(String),
    /// Run Lua with arguments.
    Lua(String, Vec<rmpv::Value>),
    /// Feed keys through nvim_input.
    Keys(String),
    FocusGrid,
    Spawn(Task),
}

/// Pixel rectangles of every region for this frame.
#[derive(Clone, Debug, Default)]
pub struct Layout {
    pub activity: Rect,
    pub sidebar: Option<Rect>,
    pub tabs: Rect,
    pub grid: Rect,
    pub panel: Option<Rect>,
    pub status: Rect,
    pub sidebar_handle: Option<Rect>,
    pub panel_handle: Option<Rect>,
}

pub struct Workbench {
    pub view: View,
    pub sidebar_open: bool,
    pub sidebar_width: f32,
    pub panel_open: bool,
    pub panel_height: f32,
    pub panel_tab: PanelTab,
    pub focus: Focus,
    pub nvim: NvimState,
    pub diagnostics: Vec<Diagnostic>,
    pub explorer: Option<explorer::Explorer>,
    pub search: search::SearchView,
    pub git: git::GitView,
    pub palette: Option<Palette>,
    pub screens: Vec<Screen>,
    pub active_screen: Option<Screen>,
    pub settings: settings::SettingsScreen,
    pub plugins: plugins::PluginsScreen,
    pub problems_list: ListState,
    pub output: Vec<String>,
    pub output_list: ListState,
    pub layout: Layout,
    drag: Option<Drag>,
    files_cache: Option<(PathBuf, Vec<String>)>,
    next_generation: u64,
    welcome_shown: bool,
    startup_settings_applied: bool,
    /// A category or tab to show once the screen's model arrives (the --screen flag).
    pub start_part: Option<String>,
}

#[derive(Clone, Copy, Debug)]
enum Drag {
    Sidebar,
    Panel,
}

impl Default for Workbench {
    fn default() -> Self {
        Self::new()
    }
}

impl Workbench {
    pub fn new() -> Self {
        Workbench {
            view: View::Explorer,
            sidebar_open: true,
            sidebar_width: 260.0,
            panel_open: false,
            panel_height: 180.0,
            panel_tab: PanelTab::Problems,
            focus: Focus::Grid,
            nvim: NvimState::default(),
            diagnostics: Vec::new(),
            explorer: None,
            search: search::SearchView::default(),
            git: git::GitView::default(),
            palette: None,
            screens: Vec::new(),
            active_screen: None,
            settings: settings::SettingsScreen::default(),
            plugins: plugins::PluginsScreen::default(),
            problems_list: ListState::default(),
            output: Vec::new(),
            output_list: ListState::default(),
            layout: Layout::default(),
            drag: None,
            files_cache: None,
            next_generation: 1,
            welcome_shown: false,
            startup_settings_applied: false,
            start_part: None,
        }
    }

    /// Neovim sent fresh workbench state.
    pub fn state_arrived(&mut self) {
        self.sync_explorer();
        // First run: the shell asks where the person is coming from, instead of the
        // in-grid picker.
        if !self.nvim.welcomed && !self.welcome_shown {
            self.welcome_shown = true;
            self.open_screen(Screen::Welcome);
        }
    }

    /// The Settings screen's model arrived; apply the settings the shell owns.
    pub fn set_settings(&mut self, model: SettingsModel) {
        self.settings.set_model(model);
        if self.active_screen == Some(Screen::Settings) {
            if let Some(part) = self.start_part.take() {
                self.settings.show_category(&part);
            }
        }
        let exclude: Vec<String> = self
            .settings
            .value_of("exclude")
            .and_then(|v| v.as_str().map(|s| s.split(',').map(|n| n.trim().to_string()).filter(|n| !n.is_empty()).collect()))
            .unwrap_or_default();
        if !exclude.is_empty() && explorer::set_hidden(exclude) {
            if let Some(e) = &mut self.explorer {
                e.refresh();
            }
        }
        if !self.startup_settings_applied {
            self.startup_settings_applied = true;
            if let Some(v) = self.settings.value_of("panel_on_start") {
                if v.as_bool() && !self.panel_open {
                    self.toggle_panel(Some(PanelTab::Problems));
                }
            }
            if let Some(v) = self.settings.value_of("sidebar_on_start") {
                if !v.as_bool() && self.sidebar_open {
                    self.toggle_sidebar(None);
                }
            }
        }
    }

    pub fn set_plugins(&mut self, model: PluginsModel) {
        self.plugins.set_model(model);
        if self.active_screen == Some(Screen::Plugins) {
            if let Some(part) = self.start_part.take() {
                if part == "extras" {
                    self.plugins.tab = plugins::Tab::Extras;
                }
            }
        }
    }

    pub fn set_import_report(&mut self, report: ImportReport) {
        self.settings.report = Some(report);
        self.open_screen(Screen::Settings);
    }

    /// Extra ripgrep arguments for the Search view: the exclude list and the rg_args setting.
    pub fn search_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        if let Some(v) = self.settings.value_of("exclude").and_then(|v| v.as_str()) {
            for name in v.split(',').map(|n| n.trim()).filter(|n| !n.is_empty()) {
                args.push("--glob".into());
                args.push(format!("!{name}"));
            }
        }
        if let Some(v) = self.settings.value_of("rg_args").and_then(|v| v.as_str()) {
            args.extend(v.split_whitespace().map(|s| s.to_string()));
        }
        args
    }

    pub fn log(&mut self, line: impl Into<String>) {
        self.output.push(line.into());
        if self.output.len() > 500 {
            self.output.remove(0);
        }
    }

    pub fn cwd(&self) -> PathBuf {
        PathBuf::from(if self.nvim.cwd.is_empty() { "." } else { &self.nvim.cwd })
    }

    /// Recompute regions for a window of `width` x `height` pixels.
    pub fn compute_layout(&mut self, width: f32, height: f32) -> Layout {
        let status = Rect::new(0.0, height - STATUS_H, width, STATUS_H);
        let body_h = (height - STATUS_H).max(0.0);
        let activity = Rect::new(0.0, 0.0, ACTIVITY_W, body_h);
        let mut x = ACTIVITY_W;
        let sidebar = if self.sidebar_open {
            let w = self.sidebar_width.clamp(SIDEBAR_MIN, (width - ACTIVITY_W - 200.0).max(SIDEBAR_MIN));
            let r = Rect::new(x, 0.0, w, body_h);
            x += w;
            Some(r)
        } else {
            None
        };
        let main_w = (width - x).max(0.0);
        let tabs = Rect::new(x, 0.0, main_w, TABS_H);
        let panel = if self.panel_open {
            let h = self.panel_height.clamp(PANEL_MIN, (body_h - TABS_H - 60.0).max(PANEL_MIN));
            Some(Rect::new(x, body_h - h, main_w, h))
        } else {
            None
        };
        let grid_bottom = panel.map(|p| p.y).unwrap_or(body_h);
        let grid = Rect::new(x, TABS_H, main_w, (grid_bottom - TABS_H).max(0.0));
        let sidebar_handle = sidebar.map(|s| Rect::new(s.right() - 3.0, 0.0, 6.0, body_h));
        let panel_handle = panel.map(|p| Rect::new(p.x, p.y - 3.0, p.w, 6.0));
        self.layout = Layout { activity, sidebar, tabs, grid, panel, status, sidebar_handle, panel_handle };
        self.layout.clone()
    }

    /// Is the pointer over chrome (not the live grid)?
    pub fn is_chrome_at(&self, x: f32, y: f32) -> bool {
        self.palette.is_some() || self.active_screen.is_some() || !self.layout.grid.contains(x, y)
    }

    /// Does the Neovim grid show right now (no native screen on top)?
    pub fn grid_visible(&self) -> bool {
        self.active_screen.is_none()
    }

    /// Chrome owns the keyboard?
    pub fn keyboard_owner(&self) -> Focus {
        if self.palette.is_some() {
            Focus::Palette
        } else if self.active_screen.is_some() && self.focus == Focus::Grid {
            Focus::Screen
        } else {
            self.focus
        }
    }

    pub fn toggle_sidebar(&mut self, view: Option<View>) {
        match view {
            Some(v) if self.sidebar_open && self.view == v => self.sidebar_open = false,
            Some(v) => {
                self.view = v;
                self.sidebar_open = true;
            }
            None => self.sidebar_open = !self.sidebar_open,
        }
        if !self.sidebar_open && self.focus == Focus::Sidebar {
            self.focus = Focus::Grid;
        }
    }

    /// Show a view and give it the keyboard (Ctrl+Shift+E/F/G).
    pub fn focus_view(&mut self, view: View) -> Vec<Action> {
        let mut actions = Vec::new();
        if !(self.sidebar_open && self.view == view) {
            self.view = view;
            self.sidebar_open = true;
        }
        self.focus = Focus::Sidebar;
        match view {
            View::Search => self.search.editing = true,
            View::Git => {
                self.git.editing = false;
                actions.push(Action::Spawn(Task::GitStatus { cwd: self.cwd() }));
            }
            _ => {}
        }
        actions
    }

    pub fn toggle_panel(&mut self, tab: Option<PanelTab>) {
        match tab {
            Some(t) if self.panel_open && self.panel_tab == t => self.panel_open = false,
            Some(t) => {
                self.panel_tab = t;
                self.panel_open = true;
            }
            None => self.panel_open = !self.panel_open,
        }
        if !self.panel_open && self.focus == Focus::Panel {
            self.focus = Focus::Grid;
        }
    }

    pub fn open_screen(&mut self, screen: Screen) {
        if !self.screens.contains(&screen) {
            self.screens.push(screen);
        }
        self.active_screen = Some(screen);
        self.focus = Focus::Grid;
    }

    pub fn close_screen(&mut self, screen: Screen) {
        self.screens.retain(|s| *s != screen);
        if self.active_screen == Some(screen) {
            self.active_screen = None;
        }
    }

    pub fn open_palette(&mut self, prefix: &str) -> Vec<Action> {
        let mut palette = Palette::new(prefix);
        let cwd = self.cwd();
        let mut actions = Vec::new();
        match &self.files_cache {
            Some((c, files)) if *c == cwd => {
                palette.files = files.clone();
                palette.files_cwd = Some(cwd);
            }
            _ => actions.push(Action::Spawn(Task::ListFiles { cwd })),
        }
        palette.refilter(&self.commands());
        self.palette = Some(palette);
        self.focus = Focus::Palette;
        actions
    }

    pub fn close_palette(&mut self) {
        self.palette = None;
        if self.focus == Focus::Palette {
            self.focus = Focus::Grid;
        }
    }

    /// Keep the explorer rooted at Neovim's cwd.
    pub fn sync_explorer(&mut self) {
        if self.nvim.cwd.is_empty() {
            return;
        }
        let cwd = PathBuf::from(&self.nvim.cwd);
        match &mut self.explorer {
            Some(e) => e.set_root(&cwd),
            None => self.explorer = Some(explorer::Explorer::new(&cwd)),
        }
    }

    /// A background task finished.
    pub fn task_done(&mut self, result: TaskResult) -> Vec<Action> {
        let mut actions = Vec::new();
        match result {
            TaskResult::Search { generation, hits, error } => {
                if generation == self.search.generation {
                    self.search.hits = hits;
                    self.search.error = error;
                    self.search.searching = false;
                    self.search.list.selected = 0;
                    self.search.list.scroll = 0;
                }
            }
            TaskResult::GitStatus(status) => {
                self.git.status = status;
                self.git.loaded = true;
                self.git.busy = false;
                if let Some(e) = &self.git.status.error {
                    self.git.last_error = Some(e.clone());
                }
            }
            TaskResult::GitDone { error } => {
                self.git.busy = false;
                self.git.last_error = error.clone();
                if let Some(e) = error {
                    self.log(format!("git: {e}"));
                } else {
                    self.git.message.set("");
                }
                actions.push(Action::Spawn(Task::GitStatus { cwd: self.cwd() }));
                if let Some(e) = &mut self.explorer {
                    e.refresh();
                }
            }
            TaskResult::Files { cwd, files } => {
                if let Some(p) = &mut self.palette {
                    p.files = files.clone();
                    p.files_cwd = Some(cwd.clone());
                    let cmds = self.commands();
                    if let Some(p) = &mut self.palette {
                        p.refilter(&cmds);
                    }
                }
                self.files_cache = Some((cwd, files));
            }
        }
        actions
    }

    /// Everything the palette can run.
    pub fn commands(&self) -> Vec<PaletteItem> {
        use PaletteCommand as C;
        use PaletteSource as S;
        let shell = |title: &str, key: &'static str, vim: &'static str, command: C| PaletteItem { title: title.into(), source: S::Shell, key, vim, command };
        let ex = |cmd: &str| PaletteItem { title: format!(":{cmd}"), source: S::Ex, key: "", vim: "", command: C::Ex(cmd.into()) };
        let mut items = vec![
            shell("Toggle sidebar", "Ctrl+B", "Space e", C::ToggleSidebar),
            shell("Toggle bottom panel", "Ctrl+`", "", C::TogglePanel),
            shell("View: Explorer", "Ctrl+Shift+E", "Space e", C::ShowView(View::Explorer)),
            shell("View: Search files", "Ctrl+Shift+F", "Space /", C::ShowView(View::Search)),
            shell("View: Source control", "Ctrl+Shift+G", "Space g g", C::ShowView(View::Git)),
            shell("View: Problems", "Ctrl+Shift+M", "Space x x", C::ShowPanel(PanelTab::Problems)),
            shell("View: Output", "", "", C::ShowPanel(PanelTab::Output)),
            shell("Terminal: Toggle", "", "Ctrl+/ (Stage 4)", C::Ex("lua Snacks.terminal()".into())),
            shell("Preferences: Open Settings", "Ctrl+,", "", C::Screen(Screen::Settings)),
            shell("Plugins: Browse", "Ctrl+Shift+X", ":Lazy", C::Screen(Screen::Plugins)),
            shell("Plugins: LazyVim extras", "", ":LazyExtras", C::Ex("LazyExtras".into())),
            shell("Plugins: Update all", "", ":Lazy update", C::Ex("Lazy update".into())),
            shell("Welcome: Choose your stage", "", ":NvsWelcome", C::Screen(Screen::Welcome)),
            shell("Learn: Open the lessons", "", ":NvsTutor", C::Ex("NvsTutor".into())),
            shell("Learn: Progress and stages", "", "", C::Screen(Screen::Learn)),
            shell("Ask: How do I…", "F1", "Space ?", C::Ex("NvsAsk".into())),
            shell("Local AI: Status", "", ":NvsAI status", C::Ex("NvsAI status".into())),
            shell("Local AI: Choose or download a model", "", ":NvsModel", C::Ex("NvsModel".into())),
            shell("Go to file", "Ctrl+P", "Space Space", C::Keys("<cmd>lua Snacks.picker.files()<CR>".into())),
            shell("Go to symbol", "Ctrl+Shift+O", "Space s s", C::Keys("<cmd>lua Snacks.picker.lsp_symbols()<CR>".into())),
            shell("Format document", "Shift+Alt+F", "Space c f", C::Ex("lua LazyVim.format({ force = true })".into())),
            shell("Go to definition", "F12", "gd", C::Ex("lua vim.lsp.buf.definition()".into())),
            shell("Find references", "Shift+F12", "grr", C::Ex("lua vim.lsp.buf.references()".into())),
            shell("Rename symbol", "F2", "grn", C::Ex("lua vim.lsp.buf.rename()".into())),
            shell("Code action", "Ctrl+.", "gra", C::Ex("lua vim.lsp.buf.code_action()".into())),
            shell("Save file", "Ctrl+S", ":w", C::Ex("write".into())),
            shell("Close buffer", "Ctrl+W", "Space b d", C::Ex("lua Snacks.bufdelete()".into())),
            shell("Neovim: Check health", "", ":checkhealth", C::Ex("checkhealth".into())),
        ];
        for n in 1..=4u32 {
            let names = ["VS Code keys", "Hybrid", "Modal with safety net", "Pure Neovim"];
            items.push(PaletteItem { title: format!("Learn: Switch to Stage {n}, {}", names[n as usize - 1]), source: S::Shell, key: "", vim: "", command: C::Stage(n) });
        }
        items.push(shell("Coach: How often hints repeat", "", ":NvsCoach", C::Ex("NvsCoach".into())));
        for cmd in ["w", "q", "wq", "NvsAsk", "NvsTutor", "NvsStage", "NvsCoach", "NvsSettings", "NvsAI status", "NvsModel", "NvsWelcome", "LazyExtras", "Tutor", "Lazy", "Mason", "LspInfo", "checkhealth", "set relativenumber!", "set wrap!", "set spell!", "vsplit", "split", "terminal", "Trouble diagnostics toggle", "e $MYVIMRC"] {
            items.push(ex(cmd));
        }
        items
    }

    fn run_palette_command(&mut self, command: PaletteCommand, actions: &mut Vec<Action>) {
        match command {
            PaletteCommand::ToggleSidebar => self.toggle_sidebar(None),
            PaletteCommand::TogglePanel => self.toggle_panel(None),
            PaletteCommand::ShowView(v) => actions.extend(self.focus_view(v)),
            PaletteCommand::ShowPanel(t) => {
                self.toggle_panel(Some(t));
                if self.panel_open {
                    self.focus = Focus::Panel;
                }
            }
            PaletteCommand::Ex(cmd) => {
                actions.push(Action::Command(cmd));
                actions.push(Action::FocusGrid);
            }
            PaletteCommand::Keys(keys) => {
                actions.push(Action::Keys(keys));
                actions.push(Action::FocusGrid);
            }
            PaletteCommand::OpenFile(rel) => {
                let path = self.cwd().join(rel);
                actions.push(Action::Lua("vim.cmd.edit(vim.fn.fnameescape(...))".into(), vec![rmpv::Value::from(path.to_string_lossy().as_ref())]));
                self.active_screen = None;
                actions.push(Action::FocusGrid);
            }
            PaletteCommand::Stage(n) => {
                actions.push(Action::Command(format!("NvsStage {n}")));
                actions.push(Action::FocusGrid);
            }
            PaletteCommand::Screen(s) => self.open_screen(s),
        }
    }

    /// Draw the chrome and handle its input for this pass.
    pub fn draw(&mut self, p: &mut Painter, input: &UiInput) -> Result<Vec<Action>, AtlasFull> {
        let mut actions = Vec::new();
        self.handle_drags(input);
        let layout = self.layout.clone();

        // Focus follows clicks (the palette swallows them).
        if self.palette.is_none() {
            for e in &input.events {
                if let UiEvent::PointerDown { x, y, .. } = e {
                    if layout.grid.contains(*x, *y) {
                        self.focus = Focus::Grid;
                    } else if layout.sidebar.map(|r| r.contains(*x, *y)).unwrap_or(false) {
                        self.focus = Focus::Sidebar;
                    } else if layout.panel.map(|r| r.contains(*x, *y)).unwrap_or(false) {
                        self.focus = Focus::Panel;
                    }
                }
            }
        }

        self.draw_activity(p, input, layout.activity, &mut actions)?;
        if let Some(rect) = layout.sidebar {
            self.draw_sidebar(p, input, rect, &mut actions)?;
        }
        self.draw_tabs(p, input, layout.tabs, &mut actions)?;
        if let Some(screen) = self.active_screen {
            self.draw_screen(p, input, screen, layout.grid, &mut actions)?;
        }
        if let Some(rect) = layout.panel {
            self.draw_panel(p, input, rect, &mut actions)?;
        }
        self.draw_status(p, input, layout.status, &mut actions)?;
        if let Some(h) = layout.sidebar_handle {
            if input.hovered(&h) || matches!(self.drag, Some(Drag::Sidebar)) {
                p.rect(h.x + 2.0, h.y, 2.0, h.h, theme::SPECTRAL);
            }
        }
        if let Some(h) = layout.panel_handle {
            if input.hovered(&h) || matches!(self.drag, Some(Drag::Panel)) {
                p.rect(h.x, h.y + 2.0, h.w, 2.0, theme::SPECTRAL);
            }
        }
        if self.palette.is_some() {
            self.draw_palette(p, input, &mut actions)?;
        }
        Ok(actions)
    }

    fn handle_drags(&mut self, input: &UiInput) {
        for e in &input.events {
            match e {
                UiEvent::PointerDown { x, y, right: false } => {
                    if self.layout.sidebar_handle.map(|h| h.contains(*x, *y)).unwrap_or(false) {
                        self.drag = Some(Drag::Sidebar);
                    } else if self.layout.panel_handle.map(|h| h.contains(*x, *y)).unwrap_or(false) {
                        self.drag = Some(Drag::Panel);
                    }
                }
                UiEvent::PointerMove { x, y } => match self.drag {
                    Some(Drag::Sidebar) => self.sidebar_width = (*x - ACTIVITY_W).max(SIDEBAR_MIN),
                    Some(Drag::Panel) => self.panel_height = (self.layout.status.y - *y).max(PANEL_MIN),
                    None => {}
                },
                UiEvent::PointerUp { .. } => self.drag = None,
                _ => {}
            }
        }
    }

    fn draw_activity(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        p.rect(rect.x, rect.y, rect.w, rect.h, theme::CRYPT);
        p.rect(rect.right() - 2.0, rect.y, 2.0, rect.h, theme::VOID);
        let mut y = rect.y + 6.0;
        for view in View::ALL {
            let r = Rect::new(rect.x + 4.0, y, 36.0, 36.0);
            let on = self.sidebar_open && self.view == view;
            if input.clicked(&r) {
                if on {
                    self.toggle_sidebar(Some(view));
                } else {
                    actions.extend(self.focus_view(view));
                }
            }
            if on {
                p.rect(r.x, r.y, r.w, r.h, theme::CRYPT_HI);
                ui::bevel(p, r, false);
            }
            let color = if on { theme::SPECTRAL } else if input.hovered(&r) { theme::BONE } else { theme::ASH };
            p.icon(view.icon(), r.x + 8.0, r.y + 8.0, 2, color)?;
            let badge = match view {
                View::Git if self.git.loaded => self.git.status.staged.len() + self.git.status.unstaged.len(),
                _ => 0,
            };
            if badge > 0 {
                let text = badge.min(99).to_string();
                let cw = p.fonts.metrics().width;
                let w = text.len() as f32 * cw + 4.0;
                p.rect(r.right() - w, r.bottom() - 12.0, w, 12.0, theme::SPECTRAL);
                ui::label(p, &text, r.right() - w + 2.0, r.bottom() - 12.0, 2, theme::VOID)?;
            }
            y += 40.0;
        }
        // Settings at the bottom.
        let r = Rect::new(rect.x + 4.0, rect.bottom() - 42.0, 36.0, 36.0);
        if input.clicked(&r) {
            self.open_screen(Screen::Settings);
        }
        let on = self.active_screen == Some(Screen::Settings);
        let color = if on { theme::SPECTRAL } else if input.hovered(&r) { theme::BONE } else { theme::ASH };
        p.icon("settings", r.x + 8.0, r.y + 8.0, 2, color)?;
        Ok(())
    }

    fn draw_sidebar(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        p.rect(rect.x, rect.y, rect.w, rect.h, theme::CRYPT_HI);
        p.rect(rect.right() - 2.0, rect.y, 2.0, rect.h, theme::VOID);
        if self.focus == Focus::Sidebar {
            p.rect(rect.x, rect.y, rect.w, 2.0, theme::NECROTIC);
        }
        let head = Rect::new(rect.x, rect.y + 2.0, rect.w - 2.0, 28.0);
        let body = Rect::new(rect.x, rect.y + 30.0, rect.w - 2.0, rect.h - 30.0);
        let focused = self.focus == Focus::Sidebar && self.palette.is_none();
        match self.view {
            View::Explorer => self.draw_explorer(p, input, head, body, focused, actions),
            View::Search => self.draw_search(p, input, head, body, focused, actions),
            View::Git => self.draw_git(p, input, head, body, focused, actions),
            other => {
                widgets::heading(p, head, other.title(), None)?;
                let cw = p.fonts.metrics().width;
                let cells = ((body.w - 20.0) / cw) as usize;
                match other {
                    View::Ask => {
                        ui::label(p, "Ask runs inside the editor for now:", body.x + 10.0, body.y + 4.0, cells, theme::BONE_DIM)?;
                        ui::label(p, "press F1 or Space ? and type a question.", body.x + 10.0, body.y + 4.0 + widgets::ROW_HEIGHT, cells, theme::BONE_DIM)?;
                        if widgets::button(p, input, Rect::new(body.x + 10.0, body.y + 60.0, 120.0, 24.0), "Open Ask", true)? {
                            actions.push(Action::Command("NvsAsk".into()));
                            actions.push(Action::FocusGrid);
                        }
                    }
                    View::Learn => {
                        ui::label(p, "Lessons and stages live on the Learn screen.", body.x + 10.0, body.y + 4.0, cells, theme::BONE_DIM)?;
                        if widgets::button(p, input, Rect::new(body.x + 10.0, body.y + 36.0, 150.0, 24.0), "Open Learn", true)? {
                            self.open_screen(Screen::Learn);
                        }
                        if widgets::button(p, input, Rect::new(body.x + 10.0, body.y + 66.0, 150.0, 24.0), "Open the lessons", false)? {
                            actions.push(Action::Command("NvsTutor".into()));
                            actions.push(Action::FocusGrid);
                        }
                    }
                    View::Plugins => {
                        ui::label(p, "The plugin browser is a screen.", body.x + 10.0, body.y + 4.0, cells, theme::BONE_DIM)?;
                        if widgets::button(p, input, Rect::new(body.x + 10.0, body.y + 36.0, 150.0, 24.0), "Open Plugins", true)? {
                            self.open_screen(Screen::Plugins);
                        }
                        if widgets::button(p, input, Rect::new(body.x + 10.0, body.y + 66.0, 150.0, 24.0), ":Lazy", false)? {
                            actions.push(Action::Command("Lazy".into()));
                            actions.push(Action::FocusGrid);
                        }
                    }
                    View::Debug => {
                        ui::label(p, "Debugging uses nvim-dap (the dap.core extra).", body.x + 10.0, body.y + 4.0, cells, theme::BONE_DIM)?;
                        ui::label(p, "Space d shows its keys once the extra is on.", body.x + 10.0, body.y + 4.0 + widgets::ROW_HEIGHT, cells, theme::ASH)?;
                    }
                    _ => {}
                }
                if focused {
                    for k in input.keys() {
                        if k.named(NamedKey::Escape) {
                            actions.push(Action::FocusGrid);
                        }
                    }
                }
                Ok(())
            }
        }
    }

    fn draw_explorer(&mut self, p: &mut Painter, input: &UiInput, head: Rect, body: Rect, focused: bool, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        let name = self.explorer.as_ref().map(|e| e.root_path().file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()).unwrap_or_default();
        widgets::heading(p, head, "Explorer", Some(&name))?;
        let Some(explorer) = self.explorer.as_mut() else {
            ui::label(p, "No folder open", body.x + 10.0, body.y + 4.0, 30, theme::ASH)?;
            return Ok(());
        };
        let rows: Vec<Row> = explorer
            .rows()
            .iter()
            .map(|n| {
                let mut row = Row::new(n.name.clone());
                row.indent = n.depth as f32 * 12.0;
                if n.is_dir {
                    row.toggle = Some(n.expanded);
                    row.icon = Some(("folder", theme::GOLD));
                } else {
                    row.indent += 12.0;
                    row.icon = Some(("file", file_color(&n.name)));
                }
                row
            })
            .collect();
        let resp = widgets::list(p, input, body, &mut explorer.list, &rows, focused)?;
        if let Some(i) = resp.activated {
            if let Some(path) = explorer.activate(i) {
                actions.push(Action::Lua("vim.cmd.edit(vim.fn.fnameescape(...))".into(), vec![rmpv::Value::from(path.to_string_lossy().as_ref())]));
                self.active_screen = None;
                actions.push(Action::FocusGrid);
            }
        }
        if let Some(i) = resp.collapse {
            explorer.collapse(i);
        }
        if resp.escape {
            actions.push(Action::FocusGrid);
        }
        Ok(())
    }

    fn draw_search(&mut self, p: &mut Painter, input: &UiInput, head: Rect, body: Rect, focused: bool, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        widgets::heading(p, head, "Search", None)?;
        let field = Rect::new(body.x + 10.0, body.y + 4.0, body.w - 20.0, 24.0);
        let editing = focused && self.search.editing;
        let resp = widgets::text_field(p, input, field, &mut self.search.query, "Search (ripgrep)", editing)?;
        if resp.clicked {
            self.search.editing = true;
            self.focus = Focus::Sidebar;
        }
        let query = self.search.query.text.trim().to_string();
        if (resp.changed && query.chars().count() >= 2) || (resp.submitted && !query.is_empty()) {
            self.search.generation = self.next_generation;
            self.next_generation += 1;
            self.search.searching = true;
            actions.push(Action::Spawn(Task::Search { generation: self.search.generation, cwd: self.cwd(), query: query.clone(), args: self.search_args() }));
        }
        if resp.changed && query.is_empty() {
            self.search.hits.clear();
            self.search.error = None;
        }
        if resp.submitted || resp.down {
            self.search.editing = false;
        }
        if resp.cancelled {
            self.search.editing = false;
            if self.search.hits.is_empty() {
                actions.push(Action::FocusGrid);
            }
        }
        let cw = p.fonts.metrics().width;
        let cells = ((body.w - 20.0) / cw) as usize;
        let note_y = field.bottom() + 6.0;
        let note = if let Some(e) = &self.search.error {
            e.clone()
        } else if self.search.searching {
            "Searching…".into()
        } else if query.is_empty() {
            "Type to search".into()
        } else {
            format!("{} result{} in {} file{}", self.search.hits.len(), if self.search.hits.len() == 1 { "" } else { "s" }, self.search.file_count(), if self.search.file_count() == 1 { "" } else { "s" })
        };
        ui::label(p, &note, body.x + 10.0, note_y, cells, theme::ASH)?;
        let list_rect = Rect::new(body.x, note_y + widgets::ROW_HEIGHT, body.w, body.bottom() - note_y - widgets::ROW_HEIGHT);
        let search_rows = self.search.rows();
        let rows: Vec<Row> = search_rows
            .iter()
            .map(|r| match r {
                search::SearchRow::File(f) => {
                    let mut row = Row::new(f.clone());
                    row.icon = Some(("file", theme::BONE_DIM));
                    row
                }
                search::SearchRow::Hit(i) => {
                    let hit = &self.search.hits[*i];
                    let mut row = Row::new(hit.text.clone());
                    row.indent = 16.0;
                    row.color = theme::BONE_DIM;
                    row.right = Some(hit.line.to_string());
                    row
                }
            })
            .collect();
        let list_focused = focused && !self.search.editing;
        let resp = widgets::list(p, input, list_rect, &mut self.search.list, &rows, list_focused)?;
        if let Some(i) = resp.activated {
            if let Some(search::SearchRow::Hit(h)) = search_rows.get(i) {
                let hit = &self.search.hits[*h];
                actions.push(Action::Lua(
                    "local path, lnum, col = ... vim.cmd.edit(vim.fn.fnameescape(path)) pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col - 1 })".into(),
                    vec![rmpv::Value::from(hit.path.as_str()), rmpv::Value::from(hit.line), rmpv::Value::from(hit.col)],
                ));
                self.active_screen = None;
                actions.push(Action::FocusGrid);
            }
        }
        if resp.slash {
            self.search.editing = true;
        }
        if resp.escape {
            actions.push(Action::FocusGrid);
        }
        Ok(())
    }

    fn draw_git(&mut self, p: &mut Painter, input: &UiInput, head: Rect, body: Rect, focused: bool, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        if !self.git.loaded && !self.git.busy {
            self.git.busy = true;
            actions.push(Action::Spawn(Task::GitStatus { cwd: self.cwd() }));
        }
        let branch = if self.git.status.branch.is_empty() { self.nvim.branch.clone() } else { self.git.status.branch.clone() };
        widgets::heading(p, head, "Source control", Some(&branch))?;
        let field = Rect::new(body.x + 10.0, body.y + 4.0, body.w - 20.0, 24.0);
        let editing = focused && self.git.editing;
        let resp = widgets::text_field(p, input, field, &mut self.git.message, "Commit message", editing)?;
        if resp.clicked {
            self.git.editing = true;
            self.focus = Focus::Sidebar;
        }
        if resp.cancelled || resp.down {
            self.git.editing = false;
        }
        let staged = self.git.status.staged.len();
        let commit_rect = Rect::new(body.x + 10.0, field.bottom() + 6.0, 160.0, 24.0);
        let commit_label = format!("Commit {staged} staged");
        let commit_clicked = widgets::button(p, input, commit_rect, &commit_label, staged > 0)? || (resp.submitted && editing);
        if commit_clicked {
            let message = self.git.message.text.trim().to_string();
            if staged == 0 {
                self.git.last_error = Some("Nothing staged to commit".into());
            } else if message.is_empty() {
                self.git.last_error = Some("Write a commit message first".into());
                self.git.editing = true;
            } else if !self.git.busy {
                self.git.busy = true;
                self.git.last_error = None;
                actions.push(Action::Spawn(Task::GitCommit { cwd: self.cwd(), message }));
            }
        }
        let refresh_rect = Rect::new(commit_rect.right() + 6.0, commit_rect.y, 90.0, 24.0);
        if widgets::button(p, input, refresh_rect, "Refresh", false)? && !self.git.busy {
            self.git.busy = true;
            actions.push(Action::Spawn(Task::GitStatus { cwd: self.cwd() }));
        }
        let cw = p.fonts.metrics().width;
        let cells = ((body.w - 20.0) / cw) as usize;
        let mut y = commit_rect.bottom() + 6.0;
        if let Some(e) = &self.git.last_error {
            ui::label(p, e, body.x + 10.0, y, cells, theme::VISCERA)?;
            y += widgets::ROW_HEIGHT;
        }
        let list_rect = Rect::new(body.x, y, body.w, body.bottom() - y - widgets::ROW_HEIGHT);
        let git_rows = self.git.rows();
        let rows: Vec<Row> = git_rows
            .iter()
            .map(|r| match r {
                git::GitRow::Header(title, n) => {
                    let mut row = Row::new(title.to_uppercase());
                    row.color = theme::BONE_DIM;
                    row.right = Some(n.to_string());
                    row
                }
                git::GitRow::Staged(i) | git::GitRow::Unstaged(i) => {
                    let e = match r {
                        git::GitRow::Staged(_) => &self.git.status.staged[*i],
                        _ => &self.git.status.unstaged[*i],
                    };
                    let (name, dir) = match e.path.rsplit_once('/') {
                        Some((d, n)) => (n.to_string(), d.to_string()),
                        None => (e.path.clone(), String::new()),
                    };
                    let mut row = Row::new(if dir.is_empty() { name } else { format!("{name}  {dir}") });
                    row.indent = 8.0;
                    row.icon = Some(("file", theme::BONE_DIM));
                    row.right = Some(e.status.to_string());
                    row.right_color = match e.status {
                        'M' => theme::GOLD,
                        'A' | '?' => theme::SPECTRAL,
                        'D' => theme::VISCERA,
                        _ => theme::BONE_DIM,
                    };
                    row
                }
            })
            .collect();
        let list_focused = focused && !self.git.editing;
        let resp = widgets::list(p, input, list_rect, &mut self.git.list, &rows, list_focused)?;
        if let Some(i) = resp.activated {
            match git_rows.get(i) {
                Some(git::GitRow::Staged(e)) if !self.git.busy => {
                    self.git.busy = true;
                    let path = self.git.status.staged[*e].path.clone();
                    actions.push(Action::Spawn(Task::GitStage { cwd: self.cwd(), path, stage: false }));
                }
                Some(git::GitRow::Unstaged(e)) if !self.git.busy => {
                    self.git.busy = true;
                    let path = self.git.status.unstaged[*e].path.clone();
                    actions.push(Action::Spawn(Task::GitStage { cwd: self.cwd(), path, stage: true }));
                }
                _ => {}
            }
        }
        if resp.slash {
            self.git.editing = true;
        }
        if resp.escape {
            actions.push(Action::FocusGrid);
        }
        let foot = Rect::new(body.x, body.bottom() - widgets::ROW_HEIGHT, body.w, widgets::ROW_HEIGHT);
        ui::label_centered_y(p, "Enter stages or unstages · Space g h s stages a hunk in the editor", body.x + 10.0, &foot, cells, theme::ASH)?;
        Ok(())
    }

    fn draw_tabs(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        let screen_active = self.active_screen;
        let mut tabs: Vec<Tab> = self
            .screens
            .iter()
            .map(|s| Tab { title: s.title().into(), icon: Some(("gear", theme::SPECTRAL)), dirty: false, active: screen_active == Some(*s) })
            .collect();
        let screen_count = tabs.len();
        tabs.extend(self.nvim.buffers.iter().map(|b| Tab {
            title: b.name.clone(),
            icon: Some(("file", file_color(&b.name))),
            dirty: b.modified,
            active: b.current && screen_active.is_none(),
        }));
        let resp = widgets::tab_strip(p, input, rect, &tabs)?;
        if let Some(i) = resp.activated {
            if i < screen_count {
                self.active_screen = Some(self.screens[i]);
                self.focus = Focus::Grid;
            } else if let Some(b) = self.nvim.buffers.get(i - screen_count) {
                self.active_screen = None;
                actions.push(Action::Command(format!("buffer {}", b.bufnr)));
                actions.push(Action::FocusGrid);
            }
        }
        if let Some(i) = resp.closed {
            if i < screen_count {
                let s = self.screens[i];
                self.close_screen(s);
            } else if let Some(b) = self.nvim.buffers.get(i - screen_count) {
                actions.push(Action::Lua(
                    "local ok = pcall(function() Snacks.bufdelete(...) end) if not ok then vim.cmd('bdelete ' .. ...) end".into(),
                    vec![rmpv::Value::from(b.bufnr)],
                ));
            }
        }
        Ok(())
    }

    fn draw_screen(&mut self, p: &mut Painter, input: &UiInput, screen: Screen, rect: Rect, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        p.rect(rect.x, rect.y, rect.w, rect.h, theme::CRYPT);
        let cw = p.fonts.metrics().width;
        let cells = ((rect.w - 40.0) / cw).max(0.0) as usize;
        let crumbs = Rect::new(rect.x, rect.y, rect.w, 20.0);
        ui::label_centered_y(p, screen.title(), rect.x + 12.0, &crumbs, cells, theme::BONE_DIM)?;
        p.rect(rect.x, crumbs.bottom(), rect.w, 1.0, theme::STONE);
        let y = crumbs.bottom() + 16.0;
        match screen {
            Screen::Welcome => {
                p.icon("logo", rect.x + 20.0, y, 4, theme::SPECTRAL)?;
                ui::label(p, "Welcome to nvs.ide", rect.x + 50.0, y + 4.0, cells, theme::SPECTRAL)?;
                ui::label(p, "Neovim with LazyVim underneath, and as much hand-holding as you want on top.", rect.x + 20.0, y + 40.0, cells, theme::BONE_DIM)?;
                ui::label(p, "Where are you coming from? Pick a stage; :NvsStage changes it any time.", rect.x + 20.0, y + 40.0 + widgets::ROW_HEIGHT, cells, theme::BONE_DIM)?;
                let cards = [
                    (1, "I'm coming from VS Code", "Everything works the way you know. Hints show the Vim way."),
                    (2, "I know a little Vim", "Files open ready to type; your shortcuts still work. Esc gives Normal mode."),
                    (3, "I use Vim, keep a few safety nets", "Normal mode first. Ctrl+S, Ctrl+Z, Ctrl+P and friends stay."),
                    (4, "I'm a Neovim user", "Pure LazyVim with your config. No hints."),
                ];
                let mut cy = y + 90.0;
                for (n, title, desc) in cards {
                    let r = Rect::new(rect.x + 20.0, cy, (rect.w - 40.0).min(620.0), 48.0);
                    let on = self.nvim.stage == n;
                    p.rect(r.x, r.y, r.w, r.h, if on { theme::STONE } else { theme::CRYPT_HI });
                    ui::bevel(p, r, !on);
                    ui::label(p, &n.to_string(), r.x + 12.0, r.y + 14.0, 2, if on { theme::SPECTRAL } else { theme::ASH })?;
                    ui::label(p, title, r.x + 40.0, r.y + 8.0, cells.saturating_sub(6), if on { theme::SPECTRAL } else { theme::BONE })?;
                    ui::label(p, desc, r.x + 40.0, r.y + 8.0 + widgets::ROW_HEIGHT, cells.saturating_sub(6), theme::BONE_DIM)?;
                    if input.clicked(&r) {
                        actions.push(Action::Command(format!("NvsStage {n}")));
                        actions.push(Action::Lua("require('nvs.state').data.welcomed = true require('nvs.state').save()".into(), vec![]));
                    }
                    cy += 56.0;
                }
                if widgets::button(p, input, Rect::new(rect.x + 20.0, cy + 8.0, 160.0, 24.0), "Start the lessons", true)? {
                    actions.push(Action::Command("NvsTutor".into()));
                    self.active_screen = None;
                    actions.push(Action::FocusGrid);
                }
                if widgets::button(p, input, Rect::new(rect.x + 190.0, cy + 8.0, 200.0, 24.0), "Ask how to do something", false)? {
                    actions.push(Action::Command("NvsAsk".into()));
                    self.active_screen = None;
                    actions.push(Action::FocusGrid);
                }
            }
            Screen::Settings => {
                let body = Rect::new(rect.x, crumbs.bottom(), rect.w, rect.h - crumbs.h);
                if self.settings.draw(p, input, body, actions)? {
                    self.active_screen = None;
                    actions.push(Action::FocusGrid);
                }
                return Ok(());
            }
            Screen::Plugins => {
                let body = Rect::new(rect.x, crumbs.bottom(), rect.w, rect.h - crumbs.h);
                if self.plugins.draw(p, input, body, actions)? {
                    self.active_screen = None;
                    actions.push(Action::FocusGrid);
                }
                return Ok(());
            }
            Screen::Learn => self.draw_learn(p, input, rect, y, cells, actions)?,
        }
        for k in input.keys() {
            if k.named(NamedKey::Escape) {
                self.active_screen = None;
                actions.push(Action::FocusGrid);
            }
        }
        Ok(())
    }

    fn draw_learn(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, y: f32, cells: usize, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        ui::label(p, "Your stage decides which VS Code keys nvs.ide handles before LazyVim sees them.", rect.x + 20.0, y, cells, theme::BONE_DIM)?;
        ui::label(p, "Moving between stages loses nothing; LazyVim's own keys come back at Stage 4.", rect.x + 20.0, y + widgets::ROW_HEIGHT, cells, theme::BONE_DIM)?;
        let cards = [
            (1, "VS Code keys", "Always typing. Esc stays in Insert mode; the coach shows the Vim way as you go."),
            (2, "Hybrid", "Files open ready to type and every VS Code shortcut works. Esc gives Normal mode."),
            (3, "Modal with safety net", "Normal mode first. Ctrl+S, Ctrl+Z, Ctrl+F, Ctrl+P, Ctrl+/ and Ctrl+Shift+K keep their VS Code meaning."),
            (4, "Pure Neovim", "LazyVim and your config decide every key. The coach goes quiet."),
        ];
        let mut cy = y + 2.0 * widgets::ROW_HEIGHT + 12.0;
        let card_w = (rect.w - 40.0).min(620.0);
        for (n, title, desc) in cards {
            let r = Rect::new(rect.x + 20.0, cy, card_w, 48.0);
            let on = self.nvim.stage == n;
            p.rect(r.x, r.y, r.w, r.h, if on { theme::STONE } else { theme::CRYPT_HI });
            ui::bevel(p, r, !on);
            ui::label(p, &n.to_string(), r.x + 12.0, r.y + 14.0, 2, if on { theme::SPECTRAL } else { theme::ASH })?;
            ui::label(p, title, r.x + 40.0, r.y + 8.0, cells.saturating_sub(6), if on { theme::SPECTRAL } else { theme::BONE })?;
            ui::label(p, desc, r.x + 40.0, r.y + 8.0 + widgets::ROW_HEIGHT, cells.saturating_sub(6), theme::BONE_DIM)?;
            if input.clicked(&r) && !on {
                actions.push(Action::Command(format!("NvsStage {n}")));
            }
            cy += 56.0;
        }
        // Keys 1-4 switch stages from the keyboard.
        for k in input.keys() {
            for n in 1..=4u32 {
                if k.is_char(&n.to_string()) && self.nvim.stage != n {
                    actions.push(Action::Command(format!("NvsStage {n}")));
                }
            }
        }
        cy += 6.0;
        let coach = match self.nvim.coach.as_str() {
            "always" => "every time",
            "once" => "once",
            "off" => "never",
            _ => "the first three times",
        };
        ui::label(p, &format!("The coach shows each hint {coach}. Change it in Settings > Transition or with :NvsCoach."), rect.x + 20.0, cy, cells, theme::BONE_DIM)?;
        cy += widgets::ROW_HEIGHT + 10.0;
        let mut bx = rect.x + 20.0;
        for (label, accent, what) in [("Open the lessons", true, "tutor"), ("Ask how to do something", false, "ask"), ("Keybinding cheat sheet", false, "keys"), ("Coach settings", false, "coach")] {
            let w = label.chars().count() as f32 * p.fonts.metrics().width + 24.0;
            let r = Rect::new(bx, cy, w, 24.0);
            if widgets::button(p, input, r, label, accent)? {
                match what {
                    "tutor" => {
                        actions.push(Action::Command("NvsTutor".into()));
                        self.active_screen = None;
                        actions.push(Action::FocusGrid);
                    }
                    "ask" => {
                        actions.push(Action::Command("NvsAsk".into()));
                        self.active_screen = None;
                        actions.push(Action::FocusGrid);
                    }
                    "keys" => {
                        self.settings.show_category("Keys");
                        self.open_screen(Screen::Settings);
                    }
                    _ => {
                        self.settings.show_category("Transition");
                        self.open_screen(Screen::Settings);
                    }
                }
            }
            bx += w + 8.0;
        }
        cy += 40.0;
        ui::label(p, "The lessons are Neovim's own :Tutor with an nvs.ide chapter; :NvsTutor reopens them any time.", rect.x + 20.0, cy, cells, theme::ASH)?;
        ui::label(p, "1 2 3 4 switch stages · Esc back to the editor", rect.x + 20.0, cy + widgets::ROW_HEIGHT, cells, theme::ASH)?;
        Ok(())
    }

    fn draw_panel(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        p.rect(rect.x, rect.y, rect.w, rect.h, theme::CRYPT);
        p.rect(rect.x, rect.y, rect.w, 2.0, theme::STONE_HI);
        if self.focus == Focus::Panel {
            p.rect(rect.x, rect.y, rect.w, 2.0, theme::NECROTIC);
        }
        let bar = Rect::new(rect.x, rect.y + 2.0, rect.w, 26.0);
        p.rect(bar.x, bar.bottom() - 1.0, bar.w, 1.0, theme::STONE);
        let cw = p.fonts.metrics().width;
        let mut x = bar.x + 8.0;
        let problems = self.diagnostics.len();
        let tabs = [
            (PanelTab::Problems, if problems > 0 { format!("PROBLEMS {problems}") } else { "PROBLEMS".to_string() }),
            (PanelTab::Output, "OUTPUT".to_string()),
            (PanelTab::Terminal, "TERMINAL".to_string()),
        ];
        for (tab, title) in tabs {
            let w = title.chars().count() as f32 * cw + 16.0;
            let r = Rect::new(x, bar.y, w, bar.h - 1.0);
            if input.clicked(&r) {
                self.panel_tab = tab;
                self.focus = Focus::Panel;
                if tab == PanelTab::Terminal {
                    actions.push(Action::Lua("Snacks.terminal()".into(), vec![]));
                    actions.push(Action::FocusGrid);
                }
            }
            let on = self.panel_tab == tab;
            ui::label_centered_y(p, &title, x + 8.0, &r, title.chars().count(), if on { theme::BONE } else { theme::BONE_DIM })?;
            if on {
                p.rect(r.x, r.bottom() - 2.0, r.w, 2.0, theme::SPECTRAL);
            }
            x += w + 2.0;
        }
        let close = Rect::new(bar.right() - 24.0, bar.y + 5.0, 16.0, 16.0);
        if input.clicked(&close) {
            self.toggle_panel(None);
        }
        p.icon("x", close.x + 5.0, close.y + 5.0, 1, if input.hovered(&close) { theme::BONE } else { theme::ASH })?;
        let body = Rect::new(rect.x + 4.0, bar.bottom() + 4.0, rect.w - 8.0, rect.bottom() - bar.bottom() - 8.0);
        let focused = self.focus == Focus::Panel && self.palette.is_none();
        match self.panel_tab {
            PanelTab::Problems => {
                if self.diagnostics.is_empty() {
                    ui::label(p, "No problems.", body.x + 8.0, body.y + 2.0, 40, theme::ASH)?;
                } else {
                    let rows: Vec<Row> = self
                        .diagnostics
                        .iter()
                        .map(|d| {
                            let (tag, color) = match d.severity.as_str() {
                                "error" => ("E", theme::VISCERA),
                                "warn" => ("W", theme::GOLD),
                                "hint" => ("H", theme::ASH),
                                _ => ("I", theme::CORPSE),
                            };
                            let mut row = Row::new(format!("{tag} {}", d.message));
                            row.color = color;
                            row.right = Some(format!("{}  {} [{}, {}]", d.source, d.file, d.lnum, d.col));
                            row
                        })
                        .collect();
                    let resp = widgets::list(p, input, body, &mut self.problems_list, &rows, focused)?;
                    if let Some(i) = resp.activated {
                        if let Some(d) = self.diagnostics.get(i) {
                            actions.push(Action::Lua(
                                "local path, lnum, col = ... vim.cmd.edit(vim.fn.fnameescape(path)) pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col - 1 })".into(),
                                vec![rmpv::Value::from(d.path.as_str()), rmpv::Value::from(d.lnum), rmpv::Value::from(d.col)],
                            ));
                            self.active_screen = None;
                            actions.push(Action::FocusGrid);
                        }
                    }
                    if resp.escape {
                        actions.push(Action::FocusGrid);
                    }
                }
            }
            PanelTab::Output => {
                let rows: Vec<Row> = self.output.iter().map(|l| Row::new(l.clone())).collect();
                if rows.is_empty() {
                    ui::label(p, "Nothing logged yet.", body.x + 8.0, body.y + 2.0, 40, theme::ASH)?;
                } else {
                    let resp = widgets::list(p, input, body, &mut self.output_list, &rows, focused)?;
                    if resp.escape {
                        actions.push(Action::FocusGrid);
                    }
                }
            }
            PanelTab::Terminal => {
                ui::label(p, "The terminal opens inside the editor (LazyVim's snacks terminal).", body.x + 8.0, body.y + 2.0, ((body.w - 16.0) / cw) as usize, theme::BONE_DIM)?;
                ui::label(p, "Click TERMINAL again to toggle it; Ctrl+/ does the same at Stage 4.", body.x + 8.0, body.y + 2.0 + widgets::ROW_HEIGHT, ((body.w - 16.0) / cw) as usize, theme::ASH)?;
            }
        }
        Ok(())
    }

    fn draw_status(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        p.rect(rect.x, rect.y, rect.w, rect.h, theme::STONE);
        p.rect(rect.x, rect.y, rect.w, 2.0, theme::VOID);
        let cw = p.fonts.metrics().width;
        let mut x = rect.x;
        let (mode_text, mode_bg) = if self.active_screen.is_some() { ("SCREEN", theme::GOLD) } else { mode_badge(&self.nvim.mode, self.nvim.stage) };
        let badge = Rect::new(x, rect.y + 2.0, 78.0f32.max(mode_text.len() as f32 * cw + 12.0), rect.h - 2.0);
        p.rect(badge.x, badge.y, badge.w, badge.h, mode_bg);
        ui::label_centered_y(p, mode_text, (badge.x + (badge.w - mode_text.len() as f32 * cw) / 2.0).round(), &badge, mode_text.len(), theme::VOID)?;
        x = badge.right();

        let mut segment = |p: &mut Painter, text: &str, color| -> Result<Rect, AtlasFull> {
            let w = text.chars().count() as f32 * cw + 16.0;
            let r = Rect::new(x, rect.y + 2.0, w, rect.h - 2.0);
            ui::label_centered_y(p, text, x + 8.0, &r, text.chars().count(), color)?;
            p.rect(r.right() - 1.0, r.y, 1.0, r.h, theme::VOID);
            x = r.right();
            Ok(r)
        };
        if !self.nvim.branch.is_empty() {
            let r = segment(p, &format!("\u{e725} {}", self.nvim.branch), theme::SPECTRAL)?;
            if input.clicked(&r) {
                actions.extend(self.focus_view(View::Git));
            }
        }
        let d = &self.nvim.diagnostics;
        let diag = format!("E {} W {}", d.error, d.warn);
        let r = segment(p, &diag, if d.error > 0 { theme::VISCERA } else if d.warn > 0 { theme::GOLD } else { theme::BONE_DIM })?;
        if input.clicked(&r) {
            self.toggle_panel(Some(PanelTab::Problems));
        }

        let mut right = rect.right();
        let mut right_segment = |p: &mut Painter, text: &str, color| -> Result<Rect, AtlasFull> {
            let w = text.chars().count() as f32 * cw + 16.0;
            let r = Rect::new(right - w, rect.y + 2.0, w, rect.h - 2.0);
            ui::label_centered_y(p, text, r.x + 8.0, &r, text.chars().count(), color)?;
            p.rect(r.x, r.y, 1.0, r.h, theme::VOID);
            right = r.x;
            Ok(r)
        };
        let ai = if self.nvim.ai.enabled { format!("ai: {}", if self.nvim.ai.model.is_empty() { "on".into() } else { self.nvim.ai.model.clone() }) } else { "ai: off".into() };
        let r = right_segment(p, &ai, if self.nvim.ai.enabled { theme::SPECTRAL } else { theme::BONE_DIM })?;
        if input.clicked(&r) {
            actions.push(Action::Command("NvsAI status".into()));
        }
        let stage_names = ["VS Code keys", "Hybrid", "Modal with safety net", "Pure Neovim"];
        let stage = format!("stage {} · {}", self.nvim.stage, stage_names.get((self.nvim.stage as usize).saturating_sub(1)).unwrap_or(&""));
        let r = right_segment(p, &stage, theme::SPECTRAL)?;
        if input.clicked(&r) {
            self.open_screen(Screen::Learn);
        }
        right_segment(p, &format!("Ln {}, Col {}", self.nvim.cursor.line, self.nvim.cursor.col), theme::BONE_DIM)?;
        if !self.nvim.lsp.is_empty() {
            right_segment(p, &self.nvim.lsp.join(" "), theme::BONE_DIM)?;
        }
        let focus_hint = match self.keyboard_owner() {
            Focus::Sidebar => "sidebar · j k move, Enter open, h close, / filter, Esc back",
            Focus::Panel => "panel · j k move, Enter open, Esc back",
            Focus::Palette => "palette · type, Enter run, Esc close",
            Focus::Screen => "Esc back to the editor",
            Focus::Grid => "",
        };
        if !focus_hint.is_empty() {
            let avail = ((right - x - 16.0) / cw).max(0.0) as usize;
            ui::label_centered_y(p, focus_hint, x + 8.0, &rect, avail, theme::BONE_DIM)?;
        }
        Ok(())
    }

    fn draw_palette(&mut self, p: &mut Painter, input: &UiInput, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        let main = Rect::new(self.layout.tabs.x, 0.0, self.layout.tabs.w, self.layout.status.y);
        let width = (main.w - 40.0).clamp(240.0, 640.0);
        let cw = p.fonts.metrics().width;
        let commands = self.commands();
        let Some(palette) = self.palette.as_mut() else { return Ok(()) };
        let rows_shown = palette.matches.len().min(12);
        let height = 6.0 + 26.0 + 6.0 + rows_shown as f32 * widgets::ROW_HEIGHT + 6.0 + widgets::ROW_HEIGHT + 6.0;
        let rect = Rect::new((main.x + (main.w - width) / 2.0).round(), main.y + 30.0, width, height);
        // Click outside closes.
        let mut close = false;
        for e in &input.events {
            if let UiEvent::PointerDown { x, y, .. } = e {
                if !rect.contains(*x, *y) {
                    close = true;
                }
            }
        }
        p.rect(rect.x + 4.0, rect.y + 4.0, rect.w, rect.h, theme::VOID);
        p.rect(rect.x, rect.y, rect.w, rect.h, theme::STONE);
        ui::bevel(p, rect, true);
        let field = Rect::new(rect.x + 6.0, rect.y + 6.0, rect.w - 12.0, 26.0);
        let resp = widgets::text_field(p, input, field, &mut palette.input, "Search commands, files, :ex, /text", true)?;
        if resp.changed {
            palette.refilter(&commands);
        }
        let n = palette.matches.len();
        if resp.down && n > 0 {
            palette.list.selected = (palette.list.selected + 1).min(n - 1);
        }
        if resp.up {
            palette.list.selected = palette.list.selected.saturating_sub(1);
        }
        let list_rect = Rect::new(rect.x + 6.0, field.bottom() + 6.0, rect.w - 12.0, rows_shown as f32 * widgets::ROW_HEIGHT);
        p.rect(list_rect.x, list_rect.y, list_rect.w, list_rect.h, theme::CRYPT);
        let rows: Vec<Row> = palette
            .matches
            .iter()
            .map(|(item, _)| {
                let mut row = Row::new(format!("{:<6} {}", item.source.tag(), item.title));
                let right = if !item.vim.is_empty() && !item.key.is_empty() {
                    format!("{}   {}", item.key, item.vim)
                } else if !item.key.is_empty() {
                    item.key.to_string()
                } else {
                    item.vim.to_string()
                };
                row.right = Some(right);
                row.right_color = theme::NECROTIC;
                row
            })
            .collect();
        let mut run: Option<usize> = None;
        if rows_shown > 0 {
            // The list is keyboard-driven from the field, so it is never "focused" itself.
            let lresp = widgets::list(p, input, list_rect, &mut palette.list, &rows, false)?;
            if let Some(i) = lresp.activated {
                run = Some(i);
            }
        }
        let footer = Rect::new(rect.x + 6.0, list_rect.bottom() + 6.0, rect.w - 12.0, widgets::ROW_HEIGHT);
        let foot_text = palette.footer();
        let hint = "Enter run · Esc close · Ctrl+J/K move";
        let hc = hint.chars().count();
        let hint_w = hc as f32 * cw;
        let avail = ((footer.w - 8.0 - hint_w - 16.0) / cw).max(0.0) as usize;
        ui::label_centered_y(p, &foot_text, footer.x + 4.0, &footer, avail, theme::ASH)?;
        ui::label_centered_y(p, hint, footer.right() - 4.0 - hint_w, &footer, hc, theme::ASH)?;
        if resp.submitted {
            run = Some(palette.list.selected);
            if palette.matches.is_empty() {
                // Plain Ex text without a match still runs.
                if let Some(':') = palette.prefix() {
                    let q = palette.query();
                    if !q.is_empty() {
                        actions.push(Action::Command(q));
                        actions.push(Action::FocusGrid);
                    }
                }
                close = true;
            }
        }
        if resp.cancelled {
            close = true;
        }
        let chosen = run.and_then(|i| palette.matches.get(i).map(|(item, _)| item.command.clone()));
        if let Some(command) = chosen {
            self.close_palette();
            self.run_palette_command(command, actions);
            return Ok(());
        }
        if close {
            self.close_palette();
        }
        Ok(())
    }
}

fn file_color(name: &str) -> crate::color::Rgba {
    let ext = name.rsplit('.').next().unwrap_or("");
    match ext {
        "lua" => theme::NECROTIC,
        "rs" => theme::GOLD,
        "ts" | "js" | "tsx" | "jsx" => theme::CORPSE,
        "md" => theme::SPECTRAL,
        "json" | "toml" | "yaml" | "yml" => theme::BONE,
        _ => theme::BONE_DIM,
    }
}

fn mode_badge(mode: &str, stage: u32) -> (&'static str, crate::color::Rgba) {
    let first = mode.chars().next().unwrap_or('n');
    match first {
        'i' if stage == 1 => ("EDIT", theme::BONE_DIM),
        'i' => ("INSERT", theme::CORPSE),
        'v' | 'V' | '\u{16}' => ("VISUAL", theme::NECROTIC),
        's' | 'S' | '\u{13}' => ("SELECT", theme::NECROTIC),
        'R' => ("REPLACE", theme::VISCERA),
        'c' => ("COMMAND", theme::GOLD),
        't' => ("TERMINAL", theme::GOLD),
        _ => ("NORMAL", theme::SPECTRAL),
    }
}

#[allow(dead_code)]
fn _unused(_: TextResponse) {}
