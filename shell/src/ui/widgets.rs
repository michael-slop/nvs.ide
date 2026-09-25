//! Widgets: lists with Vim keys, single-line text fields, buttons, tab strips, scrollbars.
//! Each widget is a function over its own persistent state; the caller owns the state.

use winit::keyboard::{Key, NamedKey};

use super::{bevel, label, label_centered_y, theme, KeyPress, Rect, UiInput};
use crate::color::Rgba;
use crate::renderer::{AtlasFull, Painter};

pub const ROW_HEIGHT: f32 = 20.0;

/// A button with a bevel. Returns true when clicked this pass.
pub fn button(p: &mut Painter, input: &UiInput, rect: Rect, text: &str, accent: bool) -> Result<bool, AtlasFull> {
    let clicked = input.clicked(&rect);
    let pressed = input.mouse_down && input.hovered(&rect);
    let (bg, fg) = if accent { (theme::SPECTRAL, theme::VOID) } else { (if pressed { theme::CRYPT_HI } else { theme::STONE }, theme::BONE) };
    p.rect(rect.x, rect.y, rect.w, rect.h, bg);
    bevel(p, rect, !pressed);
    let cw = p.fonts.metrics().width;
    let cells = ((rect.w - 12.0) / cw).floor().max(0.0) as usize;
    let text_w = text.chars().count().min(cells) as f32 * cw;
    label_centered_y(p, text, (rect.x + (rect.w - text_w) / 2.0).round(), &rect, cells, fg)?;
    Ok(clicked)
}

/// One row of a list.
pub struct Row {
    pub text: String,
    /// Left padding in px (tree indent).
    pub indent: f32,
    pub color: Rgba,
    /// Optional dim text on the right.
    pub right: Option<String>,
    pub right_color: Rgba,
    /// Icon name and colour drawn before the text.
    pub icon: Option<(&'static str, Rgba)>,
    /// Draw a `+`/`-` toggle before the text (tree nodes).
    pub toggle: Option<bool>,
}

impl Row {
    pub fn new(text: impl Into<String>) -> Self {
        Row { text: text.into(), indent: 0.0, color: theme::BONE, right: None, right_color: theme::ASH, icon: None, toggle: None }
    }
}

#[derive(Default, Clone, Debug)]
pub struct ListState {
    pub selected: usize,
    pub scroll: usize,
    /// Pending `g` for `gg`.
    pub pending_g: bool,
}

#[derive(Default, Debug)]
pub struct ListResponse {
    /// Enter, `l`/`o`, or a click on the selected row.
    pub activated: Option<usize>,
    /// `h` on a row (collapse) or a click on a toggle.
    pub collapse: Option<usize>,
    pub selection_changed: bool,
    /// The user pressed Escape or `/`.
    pub escape: bool,
    pub slash: bool,
}

/// A scrollable list. Keyboard handling only when `focused`. Clicks anywhere in the list
/// select; a click on the already-selected row activates.
pub fn list(p: &mut Painter, input: &UiInput, rect: Rect, state: &mut ListState, rows: &[Row], focused: bool) -> Result<ListResponse, AtlasFull> {
    let mut resp = ListResponse::default();
    let n = rows.len();
    if n == 0 {
        return Ok(resp);
    }
    let visible = ((rect.h / ROW_HEIGHT).floor() as usize).max(1);
    let old_selected = state.selected;
    state.selected = state.selected.min(n - 1);

    if focused {
        for k in input.keys() {
            if state.pending_g {
                state.pending_g = false;
                if k.is_char("g") {
                    state.selected = 0;
                    continue;
                }
            }
            if k.is_char("j") || k.named(NamedKey::ArrowDown) {
                state.selected = (state.selected + 1).min(n - 1);
            } else if k.is_char("k") || k.named(NamedKey::ArrowUp) {
                state.selected = state.selected.saturating_sub(1);
            } else if k.is_char("G") || k.named(NamedKey::End) {
                state.selected = n - 1;
            } else if k.is_char("g") {
                state.pending_g = true;
            } else if k.named(NamedKey::Home) {
                state.selected = 0;
            } else if k.named(NamedKey::PageDown) || k.ctrl("d") {
                state.selected = (state.selected + visible / 2).min(n - 1);
            } else if k.named(NamedKey::PageUp) || k.ctrl("u") {
                state.selected = state.selected.saturating_sub(visible / 2);
            } else if k.named(NamedKey::Enter) || k.is_char("l") || k.is_char("o") {
                resp.activated = Some(state.selected);
            } else if k.is_char("h") {
                resp.collapse = Some(state.selected);
            } else if k.named(NamedKey::Escape) {
                resp.escape = true;
            } else if k.is_char("/") {
                resp.slash = true;
            }
        }
    }

    // Mouse: wheel scrolls, click selects/activates.
    let wheel = input.scrolled(&rect);
    if wheel != 0.0 {
        let delta = (wheel * 3.0) as i64;
        state.scroll = (state.scroll as i64 + delta).clamp(0, n.saturating_sub(visible) as i64) as usize;
    }
    for e in &input.events {
        if let super::UiEvent::PointerDown { x, y, right: false } = e {
            if rect.contains(*x, *y) {
                let row = state.scroll + ((*y - rect.y) / ROW_HEIGHT).floor() as usize;
                if row < n {
                    let toggle_hit = rows[row].toggle.is_some() && *x < rect.x + rows[row].indent + 20.0;
                    if row == state.selected || toggle_hit {
                        if toggle_hit && rows[row].toggle == Some(true) {
                            resp.collapse = Some(row);
                        } else {
                            resp.activated = Some(row);
                        }
                    }
                    state.selected = row;
                }
            }
        }
    }

    // Keep the selection in view.
    if state.selected < state.scroll {
        state.scroll = state.selected;
    } else if state.selected >= state.scroll + visible {
        state.scroll = state.selected + 1 - visible;
    }
    state.scroll = state.scroll.min(n.saturating_sub(visible));
    resp.selection_changed = state.selected != old_selected;

    let cw = p.fonts.metrics().width;
    let ch = p.fonts.metrics().height;
    let has_scrollbar = n > visible;
    let inner_w = if has_scrollbar { rect.w - 8.0 } else { rect.w };
    for (i, row) in rows.iter().enumerate().skip(state.scroll).take(visible) {
        let y = rect.y + (i - state.scroll) as f32 * ROW_HEIGHT;
        let row_rect = Rect::new(rect.x, y, inner_w, ROW_HEIGHT);
        let selected = i == state.selected;
        let hovered = input.hovered(&row_rect);
        if selected {
            p.rect(row_rect.x, row_rect.y, row_rect.w, row_rect.h, if focused { theme::STONE_HI } else { theme::STONE });
            if focused {
                p.rect(row_rect.x, row_rect.y, 2.0, row_rect.h, theme::NECROTIC);
            }
        } else if hovered {
            p.rect(row_rect.x, row_rect.y, row_rect.w, row_rect.h, theme::STONE);
        }
        let mut x = rect.x + 10.0 + row.indent;
        let text_y = (y + (ROW_HEIGHT - ch) / 2.0).round();
        if let Some(open) = row.toggle {
            label(p, if open { "-" } else { "+" }, x, text_y, 1, theme::BONE_DIM)?;
            x += cw + 4.0;
        }
        if let Some((name, color)) = row.icon {
            p.icon(name, x, text_y + 1.0, 1, color)?;
            x += 12.0;
        }
        let right_cells = row.right.as_ref().map(|r| r.chars().count()).unwrap_or(0);
        let avail = ((rect.x + inner_w - 8.0 - x) / cw).floor().max(0.0) as usize;
        let text_cells = avail.saturating_sub(if right_cells > 0 { right_cells + 1 } else { 0 });
        let color = if selected && focused { theme::SPECTRAL_HI } else { row.color };
        label(p, &row.text, x, text_y, text_cells, color)?;
        if let Some(right) = &row.right {
            let rx = rect.x + inner_w - 8.0 - right_cells as f32 * cw;
            label(p, right, rx, text_y, right_cells, row.right_color)?;
        }
    }
    if has_scrollbar {
        scrollbar(p, Rect::new(rect.right() - 8.0, rect.y, 8.0, rect.h), state.scroll, visible, n);
    }
    Ok(resp)
}

pub fn scrollbar(p: &mut Painter, rect: Rect, scroll: usize, visible: usize, total: usize) {
    p.rect(rect.x, rect.y, rect.w, rect.h, theme::CRYPT);
    if total == 0 {
        return;
    }
    let thumb_h = (rect.h * visible as f32 / total as f32).max(12.0).min(rect.h);
    let range = (rect.h - thumb_h).max(0.0);
    let pos = if total > visible { range * scroll as f32 / (total - visible) as f32 } else { 0.0 };
    p.rect(rect.x + 2.0, rect.y + pos, rect.w - 4.0, thumb_h, theme::STONE_HI);
}

#[derive(Default, Clone, Debug)]
pub struct TextState {
    pub text: String,
    /// Cursor position in chars.
    pub cursor: usize,
}

impl TextState {
    pub fn set(&mut self, text: impl Into<String>) {
        self.text = text.into();
        self.cursor = self.text.chars().count();
    }

    fn byte_at(&self, chars: usize) -> usize {
        self.text.char_indices().nth(chars).map(|(i, _)| i).unwrap_or(self.text.len())
    }

    fn insert(&mut self, s: &str) {
        let at = self.byte_at(self.cursor);
        self.text.insert_str(at, s);
        self.cursor += s.chars().count();
    }

    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let start = self.byte_at(self.cursor - 1);
        let end = self.byte_at(self.cursor);
        self.text.replace_range(start..end, "");
        self.cursor -= 1;
    }

    fn delete(&mut self) {
        let len = self.text.chars().count();
        if self.cursor >= len {
            return;
        }
        let start = self.byte_at(self.cursor);
        let end = self.byte_at(self.cursor + 1);
        self.text.replace_range(start..end, "");
    }

    fn word_back(&mut self) {
        let chars: Vec<char> = self.text.chars().collect();
        let mut i = self.cursor;
        while i > 0 && chars[i - 1].is_whitespace() {
            i -= 1;
        }
        while i > 0 && !chars[i - 1].is_whitespace() {
            i -= 1;
        }
        let start = self.byte_at(i);
        let end = self.byte_at(self.cursor);
        self.text.replace_range(start..end, "");
        self.cursor = i;
    }
}

#[derive(Default, Debug)]
pub struct TextResponse {
    pub changed: bool,
    pub submitted: bool,
    pub cancelled: bool,
    /// Up/Down arrows, for lists driven from a search box.
    pub up: bool,
    pub down: bool,
    pub clicked: bool,
}

/// Apply one key press to a text field's state. Returns what happened.
pub fn text_key(state: &mut TextState, k: &KeyPress, resp: &mut TextResponse) {
    let ctrl = k.modifiers.control_key();
    match &k.key {
        Key::Named(NamedKey::Enter) => resp.submitted = true,
        Key::Named(NamedKey::Escape) => resp.cancelled = true,
        Key::Named(NamedKey::ArrowUp) => resp.up = true,
        Key::Named(NamedKey::ArrowDown) => resp.down = true,
        Key::Named(NamedKey::Backspace) => {
            if ctrl {
                state.word_back();
            } else {
                state.backspace();
            }
            resp.changed = true;
        }
        Key::Named(NamedKey::Delete) => {
            state.delete();
            resp.changed = true;
        }
        Key::Named(NamedKey::ArrowLeft) => state.cursor = state.cursor.saturating_sub(1),
        Key::Named(NamedKey::ArrowRight) => state.cursor = (state.cursor + 1).min(state.text.chars().count()),
        Key::Named(NamedKey::Home) => state.cursor = 0,
        Key::Named(NamedKey::End) => state.cursor = state.text.chars().count(),
        Key::Named(NamedKey::Space) => {
            state.insert(" ");
            resp.changed = true;
        }
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("u") => {
            state.text.clear();
            state.cursor = 0;
            resp.changed = true;
        }
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("w") => {
            state.word_back();
            resp.changed = true;
        }
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("a") => state.cursor = 0,
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("e") => state.cursor = state.text.chars().count(),
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("n") => resp.down = true,
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("p") => resp.up = true,
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("j") => resp.down = true,
        Key::Character(c) if ctrl && c.eq_ignore_ascii_case("k") => resp.up = true,
        Key::Character(_) if !ctrl && !k.modifiers.alt_key() => {
            if let Some(t) = &k.text {
                state.insert(t);
                resp.changed = true;
            }
        }
        _ => {}
    }
}

/// A single-line text field. Sunken bevel, placeholder when empty, cursor when focused.
pub fn text_field(p: &mut Painter, input: &UiInput, rect: Rect, state: &mut TextState, placeholder: &str, focused: bool) -> Result<TextResponse, AtlasFull> {
    let mut resp = TextResponse::default();
    resp.clicked = input.clicked(&rect);
    if focused {
        for k in input.keys() {
            text_key(state, k, &mut resp);
        }
    }
    p.rect(rect.x, rect.y, rect.w, rect.h, theme::VOID);
    bevel(p, rect, false);
    let cw = p.fonts.metrics().width;
    let ch = p.fonts.metrics().height;
    let cells = ((rect.w - 12.0) / cw).floor().max(1.0) as usize;
    let text_y = (rect.y + (rect.h - ch) / 2.0).round();
    let text_x = rect.x + 6.0;
    if state.text.is_empty() {
        label(p, placeholder, text_x, text_y, cells, theme::ASH)?;
    } else {
        // Scroll so the cursor stays visible.
        let total = state.text.chars().count();
        let start = if state.cursor >= cells { state.cursor + 1 - cells } else { 0 };
        let shown: String = state.text.chars().skip(start).take(cells).collect();
        label(p, &shown, text_x, text_y, cells, theme::BONE)?;
        let _ = total;
        if focused {
            let cx = text_x + (state.cursor - start) as f32 * cw;
            p.rect(cx, text_y, 2.0, ch, theme::SPECTRAL);
        }
    }
    if focused && state.text.is_empty() {
        p.rect(text_x, text_y, 2.0, ch, theme::SPECTRAL);
    }
    Ok(resp)
}

pub struct Tab {
    pub title: String,
    pub icon: Option<(&'static str, Rgba)>,
    pub dirty: bool,
    pub active: bool,
}

#[derive(Default, Debug)]
pub struct TabResponse {
    pub activated: Option<usize>,
    pub closed: Option<usize>,
}

/// The tab strip. Tabs are as wide as their title plus padding; overflow is cut.
pub fn tab_strip(p: &mut Painter, input: &UiInput, rect: Rect, tabs: &[Tab]) -> Result<TabResponse, AtlasFull> {
    let mut resp = TabResponse::default();
    p.rect(rect.x, rect.y, rect.w, rect.h, theme::STONE);
    p.rect(rect.x, rect.bottom() - 2.0, rect.w, 2.0, theme::VOID);
    let cw = p.fonts.metrics().width;
    let ch = p.fonts.metrics().height;
    let mut x = rect.x;
    for (i, tab) in tabs.iter().enumerate() {
        let title_cells = tab.title.chars().count().min(28);
        let icon_w = if tab.icon.is_some() { 14.0 } else { 0.0 };
        let w = 10.0 + icon_w + title_cells as f32 * cw + 6.0 + (if tab.dirty { 10.0 } else { 0.0 }) + 20.0;
        if x + w > rect.right() {
            break;
        }
        let tab_rect = Rect::new(x, rect.y, w, rect.h - 2.0);
        let close_rect = Rect::new(tab_rect.right() - 20.0, rect.y + (rect.h - 16.0) / 2.0 - 1.0, 16.0, 16.0);
        if input.clicked(&close_rect) {
            resp.closed = Some(i);
        } else if input.clicked(&tab_rect) {
            resp.activated = Some(i);
        }
        if tab.active {
            p.rect(tab_rect.x, tab_rect.y, tab_rect.w, tab_rect.h, theme::CRYPT);
            p.rect(tab_rect.x, tab_rect.y, tab_rect.w, 2.0, theme::SPECTRAL);
        } else if input.hovered(&tab_rect) {
            p.rect(tab_rect.x, tab_rect.y, tab_rect.w, tab_rect.h, theme::STONE_HI);
        }
        p.rect(tab_rect.right() - 2.0, tab_rect.y, 2.0, tab_rect.h, theme::VOID);
        let text_y = (rect.y + (rect.h - 2.0 - ch) / 2.0).round();
        let mut tx = x + 10.0;
        if let Some((name, color)) = tab.icon {
            p.icon(name, tx, text_y + 1.0, 1, color)?;
            tx += icon_w;
        }
        label(p, &tab.title, tx, text_y, title_cells, if tab.active { theme::BONE } else { theme::BONE_DIM })?;
        tx += title_cells as f32 * cw + 6.0;
        if tab.dirty {
            p.rect(tx, text_y + 3.0, 6.0, 6.0, theme::BONE);
        }
        let close_hover = input.hovered(&close_rect);
        if close_hover {
            p.rect(close_rect.x, close_rect.y, close_rect.w, close_rect.h, theme::STONE_HI);
        }
        p.icon("x", close_rect.x + 5.0, close_rect.y + 5.0, 1, if close_hover || tab.active { theme::BONE } else { theme::ASH })?;
        x += w;
    }
    Ok(resp)
}

/// Uppercase section heading in the sidebar ("EXPLORER").
pub fn heading(p: &mut Painter, rect: Rect, text: &str, right: Option<&str>) -> Result<(), AtlasFull> {
    let cw = p.fonts.metrics().width;
    let cells = ((rect.w - 20.0) / cw).floor().max(0.0) as usize;
    label_centered_y(p, &text.to_uppercase(), rect.x + 10.0, &rect, cells, theme::BONE_DIM)?;
    if let Some(right) = right {
        let rc = right.chars().count();
        label_centered_y(p, right, rect.right() - 10.0 - rc as f32 * cw, &rect, rc, theme::ASH)?;
    }
    Ok(())
}
