//! The Settings screen: schema-driven, from `runtime/lua/nvs/prefs.lua` over the bridge.
//! Every setting shows the Lua it maps to; a change goes back as `nvs.bridge.set_setting`.

use serde::Deserialize;
use winit::keyboard::NamedKey;

use crate::renderer::{AtlasFull, Painter};
use crate::ui::widgets::{self, ListState, Row, TextState};
use crate::ui::{self, theme, Rect, UiInput};

use super::Action;

#[derive(Deserialize, Clone, Debug, Default)]
pub struct SettingsModel {
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default)]
    pub settings: Vec<Setting>,
    #[serde(default)]
    pub keybindings: Vec<Keybinding>,
    #[serde(default)]
    pub file: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Setting {
    pub id: String,
    pub category: String,
    pub label: String,
    #[serde(default)]
    pub desc: String,
    pub kind: String,
    #[serde(default)]
    pub options: Vec<SettingOption>,
    pub value: SettingValue,
    pub default: SettingValue,
    #[serde(default)]
    pub lua: String,
    #[serde(default)]
    pub restart: bool,
    #[serde(default)]
    pub shell: bool,
    #[serde(default)]
    pub search: String,
    #[serde(default)]
    pub min: Option<f64>,
    #[serde(default)]
    pub max: Option<f64>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct SettingOption {
    pub value: SettingValue,
    pub label: String,
}

#[derive(Deserialize, Clone, Debug, PartialEq)]
#[serde(untagged)]
pub enum SettingValue {
    Bool(bool),
    Num(f64),
    Str(String),
}

impl SettingValue {
    pub fn to_rmpv(&self) -> rmpv::Value {
        match self {
            SettingValue::Bool(b) => rmpv::Value::Boolean(*b),
            SettingValue::Num(n) if n.fract() == 0.0 => rmpv::Value::from(*n as i64),
            SettingValue::Num(n) => rmpv::Value::F64(*n),
            SettingValue::Str(s) => rmpv::Value::from(s.as_str()),
        }
    }

    pub fn display(&self) -> String {
        match self {
            SettingValue::Bool(b) => b.to_string(),
            SettingValue::Num(n) if n.fract() == 0.0 => format!("{}", *n as i64),
            SettingValue::Num(n) => format!("{n}"),
            SettingValue::Str(s) => s.clone(),
        }
    }

    pub fn as_bool(&self) -> bool {
        matches!(self, SettingValue::Bool(true))
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            SettingValue::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            SettingValue::Num(n) => Some(*n),
            _ => None,
        }
    }
}

#[derive(Deserialize, Clone, Debug)]
pub struct Keybinding {
    pub lhs: String,
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub desc: String,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct ImportReport {
    #[serde(default)]
    pub dir: String,
    #[serde(default)]
    pub applied: Vec<Applied>,
    #[serde(default)]
    pub skipped: Vec<Skipped>,
    #[serde(default)]
    pub keys: Vec<ImportedKey>,
    #[serde(default)]
    pub keys_skipped: Vec<SkippedKey>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Applied {
    pub key: String,
    #[serde(default)]
    pub from: String,
    pub setting: String,
    pub value: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Skipped {
    pub key: String,
    pub why: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct ImportedKey {
    pub key: String,
    pub lhs: String,
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub desc: String,
}

#[derive(Deserialize, Clone, Debug)]
pub struct SkippedKey {
    pub key: String,
    pub command: String,
    pub why: String,
}

/// The VS Code keys nvs.ide keeps (stages 1 to 3, or the shell itself) and their Vim way.
const KEY_TABLE: &[(&str, &str, &str, bool)] = &[
    ("Save", "Ctrl+S", ":w", true),
    ("Undo", "Ctrl+Z", "u   (Ctrl+R redoes)", true),
    ("Find in file", "Ctrl+F", "/ then n, N", true),
    ("Find files", "Ctrl+P", "Space Space", true),
    ("Search the project", "Ctrl+Shift+F", "Space /", true),
    ("Command palette", "Ctrl+Shift+P, F1 asks", ": or Space s C", true),
    ("Delete line", "Ctrl+Shift+K", "dd", true),
    ("Toggle comment", "Ctrl+/", "gcc", true),
    ("Toggle sidebar", "Ctrl+B", "Space e", true),
    ("Toggle panel", "Ctrl+`", "", true),
    ("Settings", "Ctrl+,", ":NvsSettings", true),
    ("Go to definition", "F12", "gd", false),
    ("Rename symbol", "F2", "grn", false),
    ("Find references", "Shift+F12", "grr", false),
    ("Code action", "Ctrl+.", "gra", false),
    ("Go to line", "Ctrl+G", ":42 or 42G", false),
    ("Select next match", "Ctrl+D", "* then cgn", false),
    ("Column select", "Shift+Alt+drag", "Ctrl+V", false),
    ("Move between panes", "Ctrl+1..9", "Ctrl+H J K L", false),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Focus {
    Categories,
    Rows,
    Search,
}

pub struct SettingsScreen {
    pub model: SettingsModel,
    pub report: Option<ImportReport>,
    category: usize,
    cats: ListState,
    search: TextState,
    focus: Focus,
    row: usize,
    scroll: usize,
    /// A number or text setting being typed into.
    editing: Option<(String, TextState)>,
}

impl Default for SettingsScreen {
    fn default() -> Self {
        SettingsScreen {
            model: SettingsModel::default(),
            report: None,
            category: 0,
            cats: ListState::default(),
            search: TextState::default(),
            focus: Focus::Rows,
            row: 0,
            scroll: 0,
            editing: None,
        }
    }
}

const BLOCK_H: f32 = 60.0;
const CATS_W: f32 = 170.0;

impl SettingsScreen {
    pub fn set_model(&mut self, model: SettingsModel) {
        self.model = model;
        if let Some((id, _)) = &self.editing {
            if !self.model.settings.iter().any(|s| &s.id == id) {
                self.editing = None;
            }
        }
    }

    /// Jump to a category by name (Learn's "Keybinding cheat sheet" opens Keys).
    pub fn show_category(&mut self, name: &str) {
        if let Some(i) = self.model.categories.iter().position(|c| c == name) {
            self.category = i;
            self.cats.selected = i;
            self.search.set("");
            self.focus = Focus::Rows;
            self.row = 0;
            self.scroll = 0;
        }
    }

    pub fn value_of(&self, id: &str) -> Option<&SettingValue> {
        self.model.settings.iter().find(|s| s.id == id).map(|s| &s.value)
    }

    fn modified_count(&self, category: &str) -> usize {
        self.model.settings.iter().filter(|s| s.category == category && s.value != s.default).count()
    }

    fn visible(&self) -> Vec<usize> {
        let q = self.search.text.trim().to_lowercase();
        if !q.is_empty() {
            return self
                .model
                .settings
                .iter()
                .enumerate()
                .filter(|(_, s)| {
                    let hay = format!("{} {} {} {} {} {}", s.label, s.desc, s.id, s.search, s.lua, s.category).to_lowercase();
                    hay.contains(&q)
                })
                .map(|(i, _)| i)
                .collect();
        }
        let cat = self.model.categories.get(self.category).cloned().unwrap_or_default();
        self.model.settings.iter().enumerate().filter(|(_, s)| s.category == cat).map(|(i, _)| i).collect()
    }

    fn set_action(id: &str, value: &SettingValue) -> Action {
        Action::Lua("require('nvs.bridge').set_setting(...)".into(), vec![rmpv::Value::from(id), value.to_rmpv()])
    }

    /// Cycle a select setting forward or back.
    fn cycle(s: &Setting, delta: i32) -> Option<SettingValue> {
        if s.options.is_empty() {
            return None;
        }
        let n = s.options.len() as i32;
        let cur = s.options.iter().position(|o| o.value == s.value).unwrap_or(0) as i32;
        let next = ((cur + delta) % n + n) % n;
        Some(s.options[next as usize].value.clone())
    }

    pub fn draw(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, actions: &mut Vec<Action>) -> Result<bool, AtlasFull> {
        let mut close = false;
        let cw = p.fonts.metrics().width;
        let cells = |w: f32| ((w) / cw).max(0.0) as usize;

        // Top bar: search, scope, import, open file.
        let bar = Rect::new(rect.x + 12.0, rect.y + 8.0, rect.w - 24.0, 26.0);
        let import_w = 190.0;
        let open_w = 150.0;
        let field = Rect::new(bar.x, bar.y, (bar.w - import_w - open_w - 16.0).max(120.0), bar.h);
        let resp = widgets::text_field(p, input, field, &mut self.search, "Search settings, including Vim names like relativenumber  ( / )", self.focus == Focus::Search)?;
        if resp.clicked {
            self.focus = Focus::Search;
        }
        if resp.changed {
            self.row = 0;
            self.scroll = 0;
        }
        if resp.submitted || resp.down {
            self.focus = Focus::Rows;
        }
        if resp.cancelled {
            if self.search.text.is_empty() {
                self.focus = Focus::Rows;
            } else {
                self.search.set("");
            }
        }
        let import_rect = Rect::new(field.right() + 8.0, bar.y, import_w, bar.h);
        if widgets::button(p, input, import_rect, "Import from VS Code", false)? {
            actions.push(Action::Lua("require('nvs.bridge').import_vscode()".into(), vec![]));
        }
        let open_rect = Rect::new(import_rect.right() + 8.0, bar.y, open_w, bar.h);
        if widgets::button(p, input, open_rect, "Open settings.lua", false)? && !self.model.file.is_empty() {
            actions.push(Action::Lua("vim.cmd.edit(vim.fn.fnameescape(...))".into(), vec![rmpv::Value::from(self.model.file.as_str())]));
            close = true;
        }

        let body_y = bar.bottom() + 10.0;
        let body_h = (rect.bottom() - body_y - 8.0).max(0.0);

        // Categories on the left.
        let cats_rect = Rect::new(rect.x + 12.0, body_y, CATS_W, body_h);
        let searching = !self.search.text.trim().is_empty();
        let rows: Vec<Row> = self
            .model
            .categories
            .iter()
            .map(|c| {
                let m = self.modified_count(c);
                let mut row = Row::new(c.clone());
                if m > 0 {
                    row.right = Some(m.to_string());
                    row.right_color = theme::SPECTRAL;
                }
                if searching {
                    row.color = theme::BONE_DIM;
                }
                row
            })
            .collect();
        let cat_resp = widgets::list(p, input, cats_rect, &mut self.cats, &rows, self.focus == Focus::Categories)?;
        if cat_resp.selection_changed || cat_resp.activated.is_some() {
            self.category = self.cats.selected;
            self.search.set("");
            self.row = 0;
            self.scroll = 0;
            if cat_resp.activated.is_some() {
                self.focus = Focus::Rows;
            }
        }
        if cat_resp.slash {
            self.focus = Focus::Search;
        }
        if cat_resp.escape {
            close = true;
        }
        for k in input.keys() {
            if self.focus == Focus::Categories && (k.named(NamedKey::Tab) || k.is_char("l") || k.named(NamedKey::ArrowRight)) {
                self.focus = Focus::Rows;
            }
        }
        for e in &input.events {
            if let ui::UiEvent::PointerDown { x, y, .. } = e {
                if cats_rect.contains(*x, *y) {
                    self.focus = Focus::Categories;
                }
            }
        }
        p.rect(cats_rect.right() + 4.0, body_y, 1.0, body_h, theme::STONE);

        // The rows.
        let list_rect = Rect::new(cats_rect.right() + 12.0, body_y, (rect.right() - cats_rect.right() - 24.0).max(100.0), body_h);
        let mut top = list_rect.y;
        if let Some(report) = &self.report {
            let lines_n = 2 + report.applied.len().min(8) + report.keys.len().min(6) + if report.skipped.is_empty() { 0 } else { 1 } + if report.error.is_some() { 1 } else { 0 };
            let box_h = 8.0 + lines_n as f32 * widgets::ROW_HEIGHT + 8.0;
            let r = Rect::new(list_rect.x, top, list_rect.w, box_h);
            p.rect(r.x, r.y, r.w, r.h, theme::CRYPT_HI);
            ui::bevel(p, r, true);
            let mut y = r.y + 8.0;
            let w = cells(r.w - 40.0);
            ui::label(p, &format!("Imported from VS Code  ({})", report.dir), r.x + 10.0, y, w, theme::SPECTRAL)?;
            let x_rect = Rect::new(r.right() - 24.0, r.y + 6.0, 16.0, 16.0);
            p.icon("x", x_rect.x + 5.0, x_rect.y + 5.0, 1, if input.hovered(&x_rect) { theme::BONE } else { theme::ASH })?;
            let dismiss = input.clicked(&x_rect);
            y += widgets::ROW_HEIGHT;
            if let Some(e) = &report.error {
                ui::label(p, e, r.x + 10.0, y, w, theme::VISCERA)?;
                y += widgets::ROW_HEIGHT;
            }
            for a in report.applied.iter().take(8) {
                ui::label(p, &format!("{} {}  ->  {} = {}", a.key, a.from, a.setting, a.value), r.x + 10.0, y, w, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            for k in report.keys.iter().take(6) {
                ui::label(p, &format!("{}  ->  {}  {}", k.key, k.lhs, k.desc), r.x + 10.0, y, w, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            if !report.skipped.is_empty() {
                let names: Vec<&str> = report.skipped.iter().map(|s| s.key.as_str()).collect();
                ui::label(p, &format!("No equivalent, skipped: {}", names.join(", ")), r.x + 10.0, y, w, theme::ASH)?;
                y += widgets::ROW_HEIGHT;
            }
            ui::label(p, &format!("{} applied, {} keybindings, {} skipped", report.applied.len(), report.keys.len(), report.skipped.len() + report.keys_skipped.len()), r.x + 10.0, y, w, theme::BONE_DIM)?;
            top = r.bottom() + 8.0;
            if dismiss {
                self.report = None;
            }
        }
        let list_rect = Rect::new(list_rect.x, top, list_rect.w, (list_rect.bottom() - top).max(0.0));

        let visible = self.visible();
        let cat_name = self.model.categories.get(self.category).cloned().unwrap_or_default();
        let is_keys = !searching && cat_name == "Keys";
        let extra_blocks = if is_keys { 1 } else { 0 };
        let total = visible.len() + extra_blocks;
        if total == 0 {
            ui::label(p, if self.model.settings.is_empty() { "Waiting for Neovim's settings…" } else { "No setting matches. Vim option names work too, like scrolloff or rnu." }, list_rect.x + 8.0, list_rect.y + 6.0, cells(list_rect.w - 16.0), theme::ASH)?;
        }
        let per_page = ((list_rect.h / BLOCK_H).floor() as usize).max(1);
        self.row = self.row.min(total.saturating_sub(1));

        // Keyboard on the rows.
        let mut set: Option<(String, SettingValue)> = None;
        let mut commit_edit = false;
        let mut cancel_edit = false;
        if self.focus == Focus::Rows {
            if let Some((_, state)) = &mut self.editing {
                for k in input.keys() {
                    let mut r = widgets::TextResponse::default();
                    widgets::text_key(state, k, &mut r);
                    if r.submitted {
                        commit_edit = true;
                    }
                    if r.cancelled {
                        cancel_edit = true;
                    }
                }
            } else {
                for k in input.keys() {
                    if k.is_char("j") || k.named(NamedKey::ArrowDown) {
                        self.row = (self.row + 1).min(total.saturating_sub(1));
                    } else if k.is_char("k") || k.named(NamedKey::ArrowUp) {
                        self.row = self.row.saturating_sub(1);
                    } else if k.is_char("G") {
                        self.row = total.saturating_sub(1);
                    } else if k.is_char("g") {
                        self.row = 0;
                    } else if k.named(NamedKey::PageDown) || k.ctrl("d") {
                        self.row = (self.row + per_page).min(total.saturating_sub(1));
                    } else if k.named(NamedKey::PageUp) || k.ctrl("u") {
                        self.row = self.row.saturating_sub(per_page);
                    } else if k.is_char("/") {
                        self.focus = Focus::Search;
                    } else if k.is_char("h") || k.named(NamedKey::ArrowLeft) || k.named(NamedKey::Tab) && k.modifiers.shift_key() {
                        if let Some(i) = visible.get(self.row) {
                            let s = &self.model.settings[*i];
                            if s.kind == "select" {
                                if let Some(v) = Self::cycle(s, -1) {
                                    set = Some((s.id.clone(), v));
                                }
                                continue;
                            }
                        }
                        self.focus = Focus::Categories;
                    } else if k.is_char("l") || k.named(NamedKey::ArrowRight) {
                        if let Some(i) = visible.get(self.row) {
                            let s = &self.model.settings[*i];
                            if s.kind == "select" {
                                if let Some(v) = Self::cycle(s, 1) {
                                    set = Some((s.id.clone(), v));
                                }
                            }
                        }
                    } else if k.named(NamedKey::Enter) || k.named(NamedKey::Space) {
                        if let Some(i) = visible.get(self.row) {
                            let s = &self.model.settings[*i];
                            match s.kind.as_str() {
                                "bool" => set = Some((s.id.clone(), SettingValue::Bool(!s.value.as_bool()))),
                                "select" => {
                                    if let Some(v) = Self::cycle(s, 1) {
                                        set = Some((s.id.clone(), v));
                                    }
                                }
                                _ => {
                                    let mut st = TextState::default();
                                    st.set(&s.value.display());
                                    self.editing = Some((s.id.clone(), st));
                                }
                            }
                        }
                    } else if k.is_char("r") {
                        if let Some(i) = visible.get(self.row) {
                            let s = &self.model.settings[*i];
                            if s.value != s.default {
                                set = Some((s.id.clone(), s.default.clone()));
                            }
                        }
                    } else if k.named(NamedKey::Escape) {
                        if searching {
                            self.search.set("");
                        } else {
                            close = true;
                        }
                    }
                }
            }
        }
        if self.row < self.scroll {
            self.scroll = self.row;
        }
        if self.row >= self.scroll + per_page {
            self.scroll = self.row + 1 - per_page;
        }
        let wheel = input.scrolled(&list_rect);
        if wheel != 0.0 {
            let delta = (-wheel).round() as i64;
            self.scroll = (self.scroll as i64 + delta).clamp(0, total.saturating_sub(per_page) as i64) as usize;
        }

        // Draw the blocks.
        let mut y = list_rect.y;
        let mut clicked_row: Option<usize> = None;
        for (vi, idx) in visible.iter().enumerate().skip(self.scroll).take(per_page) {
            let s = &self.model.settings[*idx];
            let block = Rect::new(list_rect.x, y, list_rect.w - 12.0, BLOCK_H);
            let selected = self.focus == Focus::Rows && vi == self.row;
            if selected {
                p.rect(block.x, block.y, block.w, block.h - 4.0, theme::CRYPT_HI);
            } else if input.hovered(&block) {
                p.rect(block.x, block.y, block.w, block.h - 4.0, theme::CRYPT);
            }
            if s.value != s.default {
                p.rect(block.x, block.y + 2.0, 3.0, block.h - 8.0, theme::SPECTRAL);
            }
            let text_x = block.x + 12.0;
            let ctl_w = match s.kind.as_str() {
                "bool" => 20.0,
                "select" => 240.0,
                _ => 260.0,
            };
            let text_cells = cells(block.w - 12.0 - ctl_w - 24.0);
            let title = if searching { format!("{} · {}", s.category, s.label) } else { s.label.clone() };
            ui::label(p, &title, text_x, y + 2.0, text_cells, if selected { theme::SPECTRAL } else { theme::BONE })?;
            let mut desc = s.desc.clone();
            if s.restart {
                desc = if desc.is_empty() { "Takes effect after a restart.".into() } else { format!("{desc} Takes effect after a restart.") };
            }
            if !desc.is_empty() {
                ui::label(p, &desc, text_x, y + 2.0 + widgets::ROW_HEIGHT, cells(block.w - 24.0), theme::BONE_DIM)?;
            }
            if !s.lua.is_empty() {
                ui::label(p, &s.lua.replace('\n', "  "), text_x, y + 2.0 + 2.0 * widgets::ROW_HEIGHT, cells(block.w - 24.0), theme::ASH)?;
            }
            // The control, top right.
            let ctl = Rect::new(block.right() - ctl_w - 8.0, y + 2.0, ctl_w, 20.0);
            match s.kind.as_str() {
                "bool" => {
                    let bx = Rect::new(ctl.right() - 18.0, ctl.y + 1.0, 18.0, 18.0);
                    p.rect(bx.x, bx.y, bx.w, bx.h, theme::VOID);
                    ui::bevel(p, bx, false);
                    if s.value.as_bool() {
                        p.icon("check", bx.x + 4.0, bx.y + 4.0, 1, theme::SPECTRAL)?;
                    }
                    if input.clicked(&bx) {
                        set = Some((s.id.clone(), SettingValue::Bool(!s.value.as_bool())));
                        clicked_row = Some(vi);
                    }
                }
                "select" => {
                    let label = s.options.iter().find(|o| o.value == s.value).map(|o| o.label.clone()).unwrap_or_else(|| s.value.display());
                    let left = Rect::new(ctl.x, ctl.y, 20.0, ctl.h);
                    let right = Rect::new(ctl.right() - 20.0, ctl.y, 20.0, ctl.h);
                    let mid = Rect::new(left.right(), ctl.y, ctl.w - 40.0, ctl.h);
                    p.rect(mid.x, mid.y, mid.w, mid.h, theme::VOID);
                    ui::bevel(p, mid, false);
                    ui::label_centered_y(p, &ui::fit(&label, cells(mid.w - 8.0)), mid.x + 4.0, &mid, cells(mid.w - 8.0), theme::BONE)?;
                    p.rect(left.x, left.y, left.w, left.h, theme::STONE);
                    ui::bevel(p, left, true);
                    ui::label_centered_y(p, "<", left.x + 6.0, &left, 1, theme::BONE)?;
                    p.rect(right.x, right.y, right.w, right.h, theme::STONE);
                    ui::bevel(p, right, true);
                    ui::label_centered_y(p, ">", right.x + 6.0, &right, 1, theme::BONE)?;
                    if input.clicked(&left) {
                        if let Some(v) = Self::cycle(s, -1) {
                            set = Some((s.id.clone(), v));
                        }
                        clicked_row = Some(vi);
                    } else if input.clicked(&right) || input.clicked(&mid) {
                        if let Some(v) = Self::cycle(s, 1) {
                            set = Some((s.id.clone(), v));
                        }
                        clicked_row = Some(vi);
                    }
                }
                _ => {
                    let editing_this = matches!(&self.editing, Some((id, _)) if id == &s.id);
                    if editing_this {
                        let state = self.editing.as_mut().map(|(_, st)| st).unwrap();
                        // Keys were applied above; draw the field without re-applying.
                        let mut st = state.clone();
                        let r = widgets::text_field(p, &UiInput::default(), ctl, &mut st, "", true)?;
                        let _ = r;
                    } else {
                        let mut st = TextState::default();
                        st.set(&s.value.display());
                        let r = widgets::text_field(p, input, ctl, &mut st, if s.kind == "number" { "number" } else { "" }, false)?;
                        if r.clicked {
                            let mut es = TextState::default();
                            es.set(&s.value.display());
                            self.editing = Some((s.id.clone(), es));
                            clicked_row = Some(vi);
                        }
                    }
                }
            }
            if input.clicked(&block) && clicked_row.is_none() {
                clicked_row = Some(vi);
            }
            y += BLOCK_H;
        }
        if is_keys && self.scroll <= visible.len() && (visible.len() - self.scroll) < per_page {
            // The cheat sheet, as the last block of the Keys category.
            let n = KEY_TABLE.len() + 2 + self.model.keybindings.len().min(12) + if self.model.keybindings.is_empty() { 0 } else { 2 };
            let h = n as f32 * widgets::ROW_HEIGHT + 12.0;
            let block = Rect::new(list_rect.x, y, list_rect.w - 12.0, h.min((list_rect.bottom() - y).max(0.0)));
            let selected = self.focus == Focus::Rows && self.row == visible.len();
            if selected {
                p.rect(block.x, block.y, block.w, block.h, theme::CRYPT_HI);
            }
            let mut ky = y + 4.0;
            let c1 = block.x + 12.0;
            let c2 = block.x + 12.0 + 22.0 * cw;
            let c3 = c2 + 28.0 * cw;
            ui::label(p, "What VS Code calls it", c1, ky, 21, theme::BONE_DIM)?;
            ui::label(p, "VS Code key here", c2, ky, 27, theme::BONE_DIM)?;
            ui::label(p, "The Vim way", c3, ky, cells(block.right() - c3 - 8.0), theme::BONE_DIM)?;
            ky += widgets::ROW_HEIGHT;
            for (what, vs, vim, kept) in KEY_TABLE {
                if ky + widgets::ROW_HEIGHT > block.bottom() {
                    break;
                }
                ui::label(p, what, c1, ky, 21, theme::BONE)?;
                if *kept {
                    ui::label(p, vs, c2, ky, 27, theme::SPECTRAL)?;
                } else {
                    ui::label(p, &format!("{vs}  (not kept)"), c2, ky, 27, theme::ASH)?;
                }
                ui::label(p, vim, c3, ky, cells(block.right() - c3 - 8.0), theme::NECROTIC)?;
                ky += widgets::ROW_HEIGHT;
            }
            if !self.model.keybindings.is_empty() && ky + 2.0 * widgets::ROW_HEIGHT <= block.bottom() {
                ky += 4.0;
                ui::label(p, "Imported from keybindings.json", c1, ky, 40, theme::BONE_DIM)?;
                let clear = Rect::new(block.right() - 200.0, ky - 2.0, 190.0, 22.0);
                if widgets::button(p, input, clear, "Clear imported keys", false)? {
                    actions.push(Action::Lua("require('nvs.prefs').clear_keybindings()".into(), vec![]));
                }
                ky += widgets::ROW_HEIGHT;
                for k in self.model.keybindings.iter().take(12) {
                    if ky + widgets::ROW_HEIGHT > block.bottom() {
                        break;
                    }
                    ui::label(p, &k.desc, c1, ky, 21, theme::BONE)?;
                    ui::label(p, &k.lhs, c2, ky, 27, theme::SPECTRAL)?;
                    ui::label(p, &k.command, c3, ky, cells(block.right() - c3 - 8.0), theme::ASH)?;
                    ky += widgets::ROW_HEIGHT;
                }
            }
            if input.clicked(&block) {
                clicked_row = Some(visible.len());
            }
        }
        if let Some(r) = clicked_row {
            self.row = r;
            self.focus = Focus::Rows;
        }
        // Scrollbar.
        if total > per_page {
            widgets::scrollbar(p, Rect::new(list_rect.right() - 10.0, list_rect.y, 10.0, list_rect.h), self.scroll, per_page, total);
        }

        // Finish an edit.
        if commit_edit {
            if let Some((id, st)) = self.editing.take() {
                if let Some(s) = self.model.settings.iter().find(|s| s.id == id) {
                    let text = st.text.trim().to_string();
                    let value = if s.kind == "number" {
                        match text.parse::<f64>() {
                            Ok(n) => Some(SettingValue::Num(n)),
                            Err(_) => None,
                        }
                    } else {
                        Some(SettingValue::Str(text))
                    };
                    if let Some(v) = value {
                        set = Some((id, v));
                    }
                }
            }
        }
        if cancel_edit {
            self.editing = None;
        }
        if let Some((id, value)) = set {
            // Show the new value at once; Neovim's settings event confirms it.
            if let Some(s) = self.model.settings.iter_mut().find(|s| s.id == id) {
                s.value = value.clone();
            }
            actions.push(Self::set_action(&id, &value));
        }
        // Footer hint.
        let foot = Rect::new(rect.x, rect.bottom() - widgets::ROW_HEIGHT - 2.0, rect.w, widgets::ROW_HEIGHT);
        let hint = match self.focus {
            Focus::Search => "type to search · Enter or Down goes to the results · Esc clears",
            Focus::Categories => "j k choose a category · Enter or l opens it · / searches",
            Focus::Rows => "j k move · Enter or Space toggles or edits · h l change a choice · r resets · h or Tab back to categories · Esc closes",
        };
        ui::label_centered_y(p, hint, rect.x + 12.0, &foot, cells(rect.w - 24.0), theme::ASH)?;
        Ok(close)
    }
}
