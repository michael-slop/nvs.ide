//! The editor model: redraw events in, frame snapshots out.
//!
//! Runs on its own thread. Every `flush` produces a `Frame`: each window's lines, its
//! resolved position and draw order, the cursor, the default colours and the mode. The
//! renderer draws a frame; it never touches the grids. Ported from Neovide's
//! src/editor/mod.rs (MIT, LICENSE-NEOVIDE) minus startup-message capture and macOS extras.

mod cursor;
mod grid;
mod style;
mod window;

use std::{collections::HashMap, sync::Arc};

pub use cursor::{Cursor, CursorMode, CursorShape};
pub use grid::{CharacterGrid, GridCell};
pub use style::{Colors, Style, UnderlineStyle};
pub use window::{Line, LineFragment, Window, WindowType, Word};

use crate::bridge::{BufferEntry, EditorMode, GridLineCell, GuiOption, RedrawEvent, TabEntry, WindowAnchor};

pub const BASE_GRID_ID: u64 = 1;
/// From nvim_open_win's documentation: the message grid floats above everything at 200.
pub const MSG_ZINDEX: u64 = 200;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct SortOrder {
    pub z_index: u64,
    pub composition_order: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AnchorInfo {
    pub anchor_grid_id: u64,
    pub anchor_type: WindowAnchor,
    pub anchor_left: f64,
    pub anchor_top: f64,
    pub sort_order: SortOrder,
}

impl WindowAnchor {
    fn modified_top_left(&self, grid_left: f64, grid_top: f64, width: u64, height: u64) -> (f64, f64) {
        match self {
            WindowAnchor::NorthWest | WindowAnchor::Absolute => (grid_left, grid_top),
            WindowAnchor::NorthEast => (grid_left - width as f64, grid_top),
            WindowAnchor::SouthWest => (grid_left, grid_top - height as f64),
            WindowAnchor::SouthEast => (grid_left - width as f64, grid_top - height as f64),
        }
    }
}

/// One window as the renderer sees it.
#[derive(Clone, Debug)]
pub struct WindowFrame {
    pub id: u64,
    /// Top-left in grid-1 cells, absolute.
    pub left: f64,
    pub top: f64,
    pub width: u32,
    pub height: u32,
    pub floating: bool,
    pub sort_order: SortOrder,
    pub window_type: WindowType,
    pub lines: Vec<Line>,
}

/// Everything needed to draw one flush.
#[derive(Clone, Debug)]
pub struct Frame {
    /// Windows in draw order: base grid first, then floats by z-index and creation order.
    pub windows: Vec<WindowFrame>,
    pub cursor: Cursor,
    pub default_style: Arc<Style>,
    pub mode: EditorMode,
    /// Size of grid 1 in cells.
    pub grid_size: (u32, u32),
    /// The tab line, when ext_tabline is on.
    pub tabline: Option<TablineFrame>,
    /// Which cursor mode index is current (for blink parameters).
    pub sequence: u64,
}

#[derive(Clone, Debug)]
pub struct TablineFrame {
    pub current_tab: rmpv::Value,
    pub tabs: Vec<TabEntry>,
    pub current_buffer: rmpv::Value,
    pub buffers: Vec<BufferEntry>,
}

/// Things the editor tells the app besides frames.
#[derive(Clone, Debug)]
pub enum EditorNotice {
    Title(String),
    FontChanged(String),
    LineSpaceChanged(f32),
    MouseEnabled(bool),
    /// Neovim sent an `ext_*` option; noice.nvim can force ext_messages on after attach.
    ExtOption { name: String, enabled: bool },
    ModeChanged(EditorMode),
}

pub trait FrameSink: Send + 'static {
    fn frame(&mut self, frame: Arc<Frame>);
    fn notice(&mut self, notice: EditorNotice);
}

pub struct Editor {
    pub windows: HashMap<u64, Window>,
    pub cursor: Cursor,
    pub defined_styles: HashMap<u64, Arc<Style>>,
    pub mode_list: Vec<CursorMode>,
    pub current_mode_index: Option<u64>,
    pub current_mode: EditorMode,
    pub default_style: Arc<Style>,
    composition_order: u64,
    tabline: Option<TablineFrame>,
    sequence: u64,
}

impl Default for Editor {
    fn default() -> Self {
        Self::new()
    }
}

impl Editor {
    pub fn new() -> Self {
        Editor {
            windows: HashMap::new(),
            cursor: Cursor::default(),
            defined_styles: HashMap::new(),
            mode_list: Vec::new(),
            current_mode_index: None,
            current_mode: EditorMode::Normal,
            default_style: Arc::new(Style::new(Colors::new(
                Some(crate::color::Rgba::WHITE),
                Some(crate::color::Rgba::BLACK),
                Some(crate::color::Rgba::GREY),
            ))),
            composition_order: 0,
            tabline: None,
            sequence: 0,
        }
    }

    /// Apply one event. Returns `Some(frame)` on `flush`.
    pub fn handle_redraw_event(&mut self, event: RedrawEvent, sink: &mut impl FrameSink) {
        match event {
            RedrawEvent::SetTitle { title } => sink.notice(EditorNotice::Title(title)),
            RedrawEvent::ModeInfoSet { cursor_modes } => {
                self.mode_list = cursor_modes;
                if let Some(i) = self.current_mode_index {
                    if let Some(mode) = self.mode_list.get(i as usize) {
                        self.cursor.change_mode(mode, &self.defined_styles);
                    }
                }
            }
            RedrawEvent::OptionSet { gui_option } => self.set_option(gui_option, sink),
            RedrawEvent::ModeChange { mode, mode_index } => {
                if let Some(cursor_mode) = self.mode_list.get(mode_index as usize) {
                    self.cursor.change_mode(cursor_mode, &self.defined_styles);
                    self.current_mode_index = Some(mode_index);
                } else {
                    self.current_mode_index = None;
                }
                self.current_mode = mode.clone();
                sink.notice(EditorNotice::ModeChanged(mode));
            }
            RedrawEvent::MouseOn => sink.notice(EditorNotice::MouseEnabled(true)),
            RedrawEvent::MouseOff => sink.notice(EditorNotice::MouseEnabled(false)),
            RedrawEvent::BusyStart => self.cursor.enabled = false,
            RedrawEvent::BusyStop => self.cursor.enabled = true,
            RedrawEvent::Flush => {
                self.update_cursor_cell();
                let frame = self.snapshot();
                sink.frame(Arc::new(frame));
            }
            RedrawEvent::DefaultColorsSet { colors } => {
                self.default_style = Arc::new(Style::new(colors));
            }
            RedrawEvent::HighlightAttributesDefine { id, style, .. } => {
                self.defined_styles.insert(id, Arc::new(style));
            }
            RedrawEvent::HighlightGroupSet { .. } => {}
            RedrawEvent::CursorGoto { grid, row, column } => self.set_cursor_position(grid, column, row),
            RedrawEvent::Resize { grid, width, height } => self.resize_window(grid, width, height),
            RedrawEvent::GridLine { grid, row, column_start, cells } => self.draw_grid_line(grid, row, column_start, cells),
            RedrawEvent::Clear { grid } => {
                if let Some(window) = self.windows.get_mut(&grid) {
                    window.clear();
                }
            }
            RedrawEvent::Destroy { grid } | RedrawEvent::WindowClose { grid } => {
                self.windows.remove(&grid);
            }
            RedrawEvent::Scroll { grid, top, bottom, left, right, rows, columns } => {
                if let Some(window) = self.windows.get_mut(&grid) {
                    window.scroll_region(top, bottom, left, right, rows, columns);
                }
            }
            RedrawEvent::WindowPosition { grid, start_row, start_column, width, height } => {
                self.set_window_position(grid, start_column, start_row, width, height)
            }
            RedrawEvent::WindowFloatPosition { grid, anchor, anchor_grid, anchor_column, anchor_row, z_index, comp_index, screen_row, screen_col, .. } => {
                let anchor_type = if comp_index.is_some() {
                    WindowAnchor::Absolute
                } else {
                    self.composition_order += 1;
                    anchor
                };
                let sort_order = SortOrder { z_index, composition_order: comp_index.unwrap_or(self.composition_order) };
                let info = AnchorInfo { anchor_grid_id: anchor_grid, anchor_type, anchor_left: anchor_column, anchor_top: anchor_row, sort_order };
                self.set_window_float_position(grid, info, screen_col, screen_row);
            }
            RedrawEvent::WindowExternalPosition { grid } => {
                // No separate OS windows: show it as a float at the top-left instead of losing it.
                let info = AnchorInfo {
                    anchor_grid_id: BASE_GRID_ID,
                    anchor_type: WindowAnchor::NorthWest,
                    anchor_left: 0.0,
                    anchor_top: 0.0,
                    sort_order: SortOrder { z_index: 50, composition_order: self.composition_order },
                };
                self.set_window_float_position(grid, info, None, None);
            }
            RedrawEvent::WindowHide { grid } => {
                if let Some(window) = self.windows.get_mut(&grid) {
                    window.anchor_info = None;
                    window.hidden = true;
                }
            }
            RedrawEvent::MessageSetPosition { grid, row, scrolled, z_index, comp_index, .. } => {
                self.set_message_position(grid, row, scrolled, z_index, comp_index)
            }
            RedrawEvent::WindowViewport { .. } => {}
            RedrawEvent::WindowViewportMargins { grid, top, bottom, .. } => {
                if let Some(window) = self.windows.get_mut(&grid) {
                    window.viewport_margins = (top, bottom);
                }
            }
            RedrawEvent::TablineUpdate { current_tab, tabs, current_buffer, buffers } => {
                self.tabline = Some(TablineFrame { current_tab, tabs, current_buffer, buffers });
            }
            // cmdline / message / popupmenu events: drawn inside the grid by noice.nvim and
            // blink.cmp in v1, so these are parsed (to survive a plugin forcing the flags on)
            // and ignored here.
            RedrawEvent::CommandLineShow { .. }
            | RedrawEvent::CommandLinePosition { .. }
            | RedrawEvent::CommandLineSpecialCharacter { .. }
            | RedrawEvent::CommandLineHide
            | RedrawEvent::CommandLineBlockShow { .. }
            | RedrawEvent::CommandLineBlockAppend { .. }
            | RedrawEvent::CommandLineBlockHide
            | RedrawEvent::MessageShow { .. }
            | RedrawEvent::MessageClear
            | RedrawEvent::MessageShowMode { .. }
            | RedrawEvent::MessageShowCommand { .. }
            | RedrawEvent::MessageRuler { .. }
            | RedrawEvent::MessageHistoryShow { .. }
            | RedrawEvent::PopupmenuShow { .. }
            | RedrawEvent::PopupmenuSelect { .. }
            | RedrawEvent::PopupmenuHide
            | RedrawEvent::Suspend
            | RedrawEvent::Restart { .. } => {}
        }
    }

    fn set_option(&mut self, option: GuiOption, sink: &mut impl FrameSink) {
        match option {
            GuiOption::GuiFont(font) => sink.notice(EditorNotice::FontChanged(font)),
            GuiOption::LineSpace(ls) => sink.notice(EditorNotice::LineSpaceChanged(ls as f32)),
            GuiOption::Unknown(name, value) if name.starts_with("ext_") => {
                if let Some(enabled) = value.as_bool() {
                    sink.notice(EditorNotice::ExtOption { name, enabled });
                }
            }
            _ => {}
        }
    }

    fn resize_window(&mut self, grid: u64, width: u64, height: u64) {
        if let Some(window) = self.windows.get_mut(&grid) {
            window.resize((width, height));
            if let Some(anchor) = window.anchor_info.clone() {
                self.set_window_float_position(grid, anchor, None, None);
            }
        } else {
            let mut window = Window::new(grid, WindowType::Editor, None, (0.0, 0.0), (width, height));
            // A multigrid window can be resized before Neovim says where it goes; keep it hidden
            // until win_pos / win_float_pos / msg_set_pos shows it.
            if grid != BASE_GRID_ID {
                window.hidden = true;
            }
            self.windows.insert(grid, window);
        }
    }

    fn set_window_position(&mut self, grid: u64, left: u64, top: u64, width: u64, height: u64) {
        if let Some(window) = self.windows.get_mut(&grid) {
            window.position(None, (width, height), (left as f64, top as f64));
            window.hidden = false;
        } else {
            self.windows.insert(grid, Window::new(grid, WindowType::Editor, None, (left as f64, top as f64), (width, height)));
        }
    }

    fn set_window_float_position(&mut self, grid: u64, anchor: AnchorInfo, screen_col: Option<u64>, screen_row: Option<u64>) {
        if anchor.anchor_grid_id == grid {
            log::warn!("window {grid} asked to float relative to itself");
            return;
        }
        let parent_position = self.get_window_top_left(anchor.anchor_grid_id);
        let Some(window) = self.windows.get_mut(&grid) else {
            log::error!("float position for unknown grid {grid}");
            return;
        };
        let width = window.get_width();
        let height = window.get_height();
        let (left, top, sort_order) = if anchor.anchor_type == WindowAnchor::Absolute {
            match (screen_col, screen_row) {
                (Some(c), Some(r)) => (c as f64, r as f64, anchor.sort_order.clone()),
                _ => {
                    let (l, t) = window.grid_position;
                    (l, t, anchor.sort_order.clone())
                }
            }
        } else {
            let (mut left, mut top) = anchor.anchor_type.modified_top_left(anchor.anchor_left, anchor.anchor_top, width, height);
            if let Some((pl, pt)) = parent_position {
                left += pl;
                top += pt;
            }
            // Keep the composition order unless the z-index changed, as Neovide does.
            let sort_order = match &window.anchor_info {
                Some(old) if old.sort_order.z_index == anchor.sort_order.z_index => old.sort_order.clone(),
                _ => anchor.sort_order.clone(),
            };
            (left, top, sort_order)
        };
        let mut anchor = anchor;
        anchor.sort_order = sort_order;
        window.position(Some(anchor), (width, height), (left, top));
        window.hidden = false;
    }

    fn set_message_position(&mut self, grid: u64, grid_top: u64, scrolled: bool, z_index: Option<u64>, comp_index: Option<u64>) {
        // Neovim 0.11.3 sends an extra msg_set_pos with grid 0 (neovide#3150); ignore it.
        if grid == 0 {
            return;
        }
        let z_index = z_index.unwrap_or(MSG_ZINDEX);
        let parent_width = self.windows.get(&BASE_GRID_ID).map(|p| p.get_width()).unwrap_or(1);
        let anchor = AnchorInfo {
            anchor_grid_id: BASE_GRID_ID,
            anchor_type: WindowAnchor::NorthWest,
            anchor_left: 0.0,
            anchor_top: grid_top as f64,
            sort_order: SortOrder { z_index, composition_order: comp_index.unwrap_or(self.composition_order) },
        };
        if let Some(window) = self.windows.get_mut(&grid) {
            window.window_type = WindowType::Message { scrolled };
            let height = window.get_height();
            window.position(Some(anchor), (parent_width, height), (0.0, grid_top as f64));
            window.hidden = false;
        } else {
            self.windows.insert(grid, Window::new(grid, WindowType::Message { scrolled }, Some(anchor), (0.0, grid_top as f64), (parent_width, 1)));
        }
    }

    fn get_window_top_left(&self, grid: u64) -> Option<(f64, f64)> {
        let window = self.windows.get(&grid)?;
        match &window.anchor_info {
            Some(AnchorInfo { anchor_type: WindowAnchor::Absolute, .. }) | None => Some(window.grid_position),
            Some(info) => {
                let (pl, pt) = self.get_window_top_left(info.anchor_grid_id)?;
                let (l, t) = info.anchor_type.modified_top_left(info.anchor_left, info.anchor_top, window.get_width(), window.get_height());
                Some((pl + l, pt + t))
            }
        }
    }

    fn set_cursor_position(&mut self, grid: u64, left: u64, top: u64) {
        if let Some(window) = self.windows.get_mut(&grid) {
            if let Some(anchor) = window.anchor_info.as_mut() {
                // Neovim raises a float when the cursor enters it; mirror that.
                self.composition_order += 1;
                anchor.sort_order.composition_order = self.composition_order;
            }
        }
        self.cursor.parent_grid = grid;
        self.cursor.grid_position = (left, top);
    }

    fn draw_grid_line(&mut self, grid: u64, row: u64, column_start: u64, cells: Vec<GridLineCell>) {
        if let Some(window) = self.windows.get_mut(&grid) {
            window.draw_grid_line(row, column_start, cells, &self.defined_styles);
        }
    }

    fn update_cursor_cell(&mut self) {
        let (left, top) = self.cursor.grid_position;
        if let Some(window) = self.windows.get(&self.cursor.parent_grid) {
            let (text, style, double_width) = window.get_cursor_grid_cell(left, top);
            self.cursor.grid_cell = (text, style);
            self.cursor.double_width = double_width;
        } else {
            self.cursor.grid_cell = (" ".to_string(), None);
            self.cursor.double_width = false;
        }
    }

    /// Resolve every visible window's absolute position and draw order and copy its lines.
    pub fn snapshot(&mut self) -> Frame {
        self.sequence += 1;
        let mut windows: Vec<WindowFrame> = self
            .windows
            .values()
            .filter(|w| !w.hidden && w.get_width() > 0 && w.get_height() > 0)
            .map(|w| {
                let (left, top) = self.get_window_top_left(w.grid_id).unwrap_or(w.grid_position);
                let (floating, sort_order) = match &w.anchor_info {
                    Some(info) => (true, info.sort_order.clone()),
                    None => (false, SortOrder { z_index: 0, composition_order: if w.grid_id == BASE_GRID_ID { 0 } else { 1 } }),
                };
                WindowFrame {
                    id: w.grid_id,
                    left,
                    top,
                    width: w.get_width() as u32,
                    height: w.get_height() as u32,
                    floating,
                    sort_order,
                    window_type: w.window_type,
                    lines: w.snapshot_lines(),
                }
            })
            .collect();
        windows.sort_by(|a, b| (a.floating, &a.sort_order, a.id).cmp(&(b.floating, &b.sort_order, b.id)));
        let grid_size = self
            .windows
            .get(&BASE_GRID_ID)
            .map(|w| (w.get_width() as u32, w.get_height() as u32))
            .unwrap_or((0, 0));
        Frame {
            windows,
            cursor: self.cursor.clone(),
            default_style: self.default_style.clone(),
            mode: self.current_mode.clone(),
            grid_size,
            tabline: self.tabline.clone(),
            sequence: self.sequence,
        }
    }
}

/// Spawn the editor thread. Returns the sender for redraw events.
pub fn start_editor_thread(mut sink: impl FrameSink) -> std::sync::mpsc::Sender<Vec<RedrawEvent>> {
    let (tx, rx) = std::sync::mpsc::channel::<Vec<RedrawEvent>>();
    std::thread::Builder::new()
        .name("nvs-editor".into())
        .spawn(move || {
            let mut editor = Editor::new();
            while let Ok(events) = rx.recv() {
                for event in events {
                    editor.handle_redraw_event(event, &mut sink);
                }
            }
            log::info!("editor thread finished");
        })
        .expect("editor thread");
    tx
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Collect(Vec<Arc<Frame>>);
    impl FrameSink for Collect {
        fn frame(&mut self, frame: Arc<Frame>) {
            self.0.push(frame);
        }
        fn notice(&mut self, _notice: EditorNotice) {}
    }

    fn cells(s: &str) -> Vec<GridLineCell> {
        s.chars().map(|c| GridLineCell { text: c.to_string(), highlight_id: Some(0), repeat: None }).collect()
    }

    #[test]
    fn flush_snapshots_windows_in_draw_order() {
        let mut ed = Editor::new();
        let mut sink = Collect(vec![]);
        ed.handle_redraw_event(RedrawEvent::Resize { grid: 1, width: 10, height: 4 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::Resize { grid: 2, width: 10, height: 3 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::WindowPosition { grid: 2, start_row: 0, start_column: 0, width: 10, height: 3 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::GridLine { grid: 2, row: 0, column_start: 0, cells: cells("hello") }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::Resize { grid: 3, width: 4, height: 1 }, &mut sink);
        ed.handle_redraw_event(
            RedrawEvent::WindowFloatPosition {
                grid: 3,
                anchor: WindowAnchor::NorthWest,
                anchor_grid: 2,
                anchor_row: 1.0,
                anchor_column: 2.0,
                mouse_enabled: true,
                z_index: 50,
                comp_index: None,
                screen_row: None,
                screen_col: None,
            },
            &mut sink,
        );
        ed.handle_redraw_event(RedrawEvent::CursorGoto { grid: 2, row: 0, column: 1 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::Flush, &mut sink);
        let frame = sink.0.pop().unwrap();
        assert_eq!(frame.grid_size, (10, 4));
        let ids: Vec<u64> = frame.windows.iter().map(|w| w.id).collect();
        assert_eq!(ids, vec![1, 2, 3]);
        let float = &frame.windows[2];
        assert!(float.floating);
        assert_eq!((float.left, float.top), (2.0, 1.0));
        assert_eq!(frame.windows[1].lines[0].fragments[0].words[0].text, "hello");
        assert_eq!(frame.cursor.grid_cell.0, "e");
    }

    #[test]
    fn hidden_windows_are_not_drawn_until_positioned() {
        let mut ed = Editor::new();
        let mut sink = Collect(vec![]);
        ed.handle_redraw_event(RedrawEvent::Resize { grid: 1, width: 5, height: 2 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::Resize { grid: 4, width: 5, height: 1 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::Flush, &mut sink);
        assert_eq!(sink.0.pop().unwrap().windows.len(), 1);
        ed.handle_redraw_event(RedrawEvent::WindowPosition { grid: 4, start_row: 1, start_column: 0, width: 5, height: 1 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::Flush, &mut sink);
        assert_eq!(sink.0.pop().unwrap().windows.len(), 2);
        ed.handle_redraw_event(RedrawEvent::WindowHide { grid: 4 }, &mut sink);
        ed.handle_redraw_event(RedrawEvent::Flush, &mut sink);
        assert_eq!(sink.0.pop().unwrap().windows.len(), 1);
    }
}
