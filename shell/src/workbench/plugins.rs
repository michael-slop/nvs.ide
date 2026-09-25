//! The Plugins screen: lazy.nvim's plugin list and LazyVim's extras, from
//! `runtime/lua/nvs/plugins.lua` over the bridge.

use serde::Deserialize;
use crate::renderer::{AtlasFull, Painter};
use crate::ui::widgets::{self, ListState, Row, TextState};
use crate::ui::{self, theme, Rect, UiInput};

use super::Action;

#[derive(Deserialize, Clone, Debug, Default)]
pub struct PluginsModel {
    #[serde(default)]
    pub plugins: Vec<Plugin>,
    #[serde(default)]
    pub extras: Vec<Extra>,
    #[serde(default)]
    pub has_updates: bool,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Plugin {
    pub name: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub dir: String,
    #[serde(default)]
    pub installed: bool,
    #[serde(default)]
    pub loaded: bool,
    #[serde(default)]
    pub lazy: bool,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default)]
    pub dep: bool,
    #[serde(default)]
    pub updates: bool,
    #[serde(default)]
    pub loads: Vec<String>,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub desc: String,
    #[serde(default)]
    pub eq: Vec<String>,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize, Clone, Debug)]
pub struct Extra {
    pub name: String,
    pub module: String,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub managed: bool,
    #[serde(default)]
    pub recommended: bool,
    #[serde(default)]
    pub desc: String,
    #[serde(default)]
    pub plugins: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Installed,
    Extras,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Focus {
    Search,
    List,
}

pub struct PluginsScreen {
    pub model: PluginsModel,
    pub tab: Tab,
    search: TextState,
    list: ListState,
    focus: Focus,
}

impl Default for PluginsScreen {
    fn default() -> Self {
        PluginsScreen { model: PluginsModel::default(), tab: Tab::Installed, search: TextState::default(), list: ListState::default(), focus: Focus::List }
    }
}

impl PluginsScreen {
    pub fn set_model(&mut self, model: PluginsModel) {
        self.model = model;
    }

    fn visible_plugins(&self) -> Vec<usize> {
        let q = self.search.text.trim().to_lowercase();
        self.model
            .plugins
            .iter()
            .enumerate()
            .filter(|(_, p)| q.is_empty() || format!("{} {} {}", p.name, p.desc, p.eq.join(" ")).to_lowercase().contains(&q))
            .map(|(i, _)| i)
            .collect()
    }

    fn visible_extras(&self) -> Vec<usize> {
        let q = self.search.text.trim().to_lowercase();
        let mut idx: Vec<usize> = self
            .model
            .extras
            .iter()
            .enumerate()
            .filter(|(_, x)| q.is_empty() || format!("{} {}", x.name, x.desc).to_lowercase().contains(&q))
            .map(|(i, _)| i)
            .collect();
        // Enabled first, then recommended, then the rest, each alphabetical.
        idx.sort_by_key(|i| {
            let x = &self.model.extras[*i];
            (!x.enabled, !x.recommended, x.name.clone())
        });
        idx
    }

    pub fn draw(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, actions: &mut Vec<Action>) -> Result<bool, AtlasFull> {
        let mut close = false;
        let cw = p.fonts.metrics().width;
        let cells = |w: f32| (w / cw).max(0.0) as usize;

        // Tabs and buttons.
        let bar = Rect::new(rect.x + 12.0, rect.y + 8.0, rect.w - 24.0, 26.0);
        let n_installed = self.model.plugins.iter().filter(|p| p.installed).count();
        let n_extras = self.model.extras.iter().filter(|x| x.enabled).count();
        let tabs = [(Tab::Installed, format!("Installed {n_installed}")), (Tab::Extras, format!("Extras {n_extras} on"))];
        let mut x = bar.x;
        for (tab, title) in tabs {
            let w = title.chars().count() as f32 * cw + 20.0;
            let r = Rect::new(x, bar.y, w, bar.h);
            if widgets::button(p, input, r, &title, self.tab == tab)? && self.tab != tab {
                self.tab = tab;
                self.list = ListState::default();
            }
            x += w + 6.0;
        }
        let update_w = 120.0;
        let lazy_w = 110.0;
        let field = Rect::new(x + 6.0, bar.y, (bar.right() - x - 6.0 - update_w - lazy_w - 16.0).max(120.0), bar.h);
        let resp = widgets::text_field(p, input, field, &mut self.search, "Search plugins, or name what you used in VS Code", self.focus == Focus::Search)?;
        if resp.clicked {
            self.focus = Focus::Search;
        }
        if resp.changed {
            self.list.selected = 0;
            self.list.scroll = 0;
        }
        if resp.submitted || resp.down {
            self.focus = Focus::List;
        }
        if resp.cancelled {
            if self.search.text.is_empty() {
                self.focus = Focus::List;
            } else {
                self.search.set("");
            }
        }
        let upd = Rect::new(field.right() + 8.0, bar.y, update_w, bar.h);
        if widgets::button(p, input, upd, if self.model.has_updates { "Update all" } else { "Check updates" }, self.model.has_updates)? {
            actions.push(Action::Lua("require('nvs.bridge').plugin_action(...)".into(), vec![rmpv::Value::from(if self.model.has_updates { "update_all" } else { "check" })]));
            actions.push(Action::FocusGrid);
            close = true;
        }
        let lz = Rect::new(upd.right() + 8.0, bar.y, lazy_w, bar.h);
        if widgets::button(p, input, lz, "Open :Lazy", false)? {
            actions.push(Action::Lua("require('nvs.bridge').plugin_action(...)".into(), vec![rmpv::Value::from("open")]));
            actions.push(Action::FocusGrid);
            close = true;
        }

        let body_y = bar.bottom() + 10.0;
        let body_h = (rect.bottom() - body_y - widgets::ROW_HEIGHT - 12.0).max(0.0);
        let list_w = ((rect.w - 24.0) * 0.45).clamp(200.0, 420.0);
        let list_rect = Rect::new(rect.x + 12.0, body_y, list_w, body_h);
        let detail = Rect::new(list_rect.right() + 16.0, body_y, (rect.right() - list_rect.right() - 28.0).max(100.0), body_h);
        p.rect(detail.x - 8.0, body_y, 1.0, body_h, theme::STONE);

        let focused = self.focus == Focus::List;
        match self.tab {
            Tab::Installed => {
                let visible = self.visible_plugins();
                let rows: Vec<Row> = visible
                    .iter()
                    .map(|i| {
                        let pl = &self.model.plugins[*i];
                        let mut row = Row::new(pl.name.clone());
                        row.icon = Some(("pkg", if !pl.enabled { theme::ASH } else if pl.loaded { theme::SPECTRAL } else { theme::BONE_DIM }));
                        row.right = Some(if pl.updates { "update".into() } else if !pl.enabled { "off".into() } else if pl.loaded { "loaded".into() } else if pl.lazy { "lazy".into() } else { String::new() });
                        row.right_color = if pl.updates { theme::GOLD } else { theme::ASH };
                        if pl.dep {
                            row.color = theme::BONE_DIM;
                        }
                        row
                    })
                    .collect();
                if rows.is_empty() {
                    ui::label(p, if self.model.plugins.is_empty() { "Waiting for lazy.nvim's list…" } else { "Nothing matches." }, list_rect.x + 8.0, list_rect.y + 4.0, cells(list_rect.w - 16.0), theme::ASH)?;
                }
                let lr = widgets::list(p, input, list_rect, &mut self.list, &rows, focused)?;
                if lr.slash {
                    self.focus = Focus::Search;
                }
                if lr.escape {
                    if self.search.text.is_empty() {
                        close = true;
                    } else {
                        self.search.set("");
                    }
                }
                for e in &input.events {
                    if let ui::UiEvent::PointerDown { x, y, .. } = e {
                        if list_rect.contains(*x, *y) {
                            self.focus = Focus::List;
                        }
                    }
                }
                if let Some(i) = visible.get(self.list.selected) {
                    let pl = self.model.plugins[*i].clone();
                    self.draw_plugin(p, input, detail, &pl, actions)?;
                }
            }
            Tab::Extras => {
                let visible = self.visible_extras();
                let rows: Vec<Row> = visible
                    .iter()
                    .map(|i| {
                        let x = &self.model.extras[*i];
                        let mut row = Row::new(x.name.clone());
                        row.icon = Some(("pkg", if x.enabled { theme::SPECTRAL } else { theme::ASH }));
                        row.right = Some(if x.enabled { "on".into() } else if x.recommended { "recommended".into() } else { String::new() });
                        row.right_color = if x.enabled { theme::SPECTRAL } else { theme::GOLD };
                        row
                    })
                    .collect();
                if rows.is_empty() {
                    ui::label(p, if self.model.extras.is_empty() { "Waiting for LazyVim's extras…" } else { "Nothing matches." }, list_rect.x + 8.0, list_rect.y + 4.0, cells(list_rect.w - 16.0), theme::ASH)?;
                }
                let lr = widgets::list(p, input, list_rect, &mut self.list, &rows, focused)?;
                if lr.slash {
                    self.focus = Focus::Search;
                }
                if lr.escape {
                    if self.search.text.is_empty() {
                        close = true;
                    } else {
                        self.search.set("");
                    }
                }
                for e in &input.events {
                    if let ui::UiEvent::PointerDown { x, y, .. } = e {
                        if list_rect.contains(*x, *y) {
                            self.focus = Focus::List;
                        }
                    }
                }
                let toggle = lr.activated.is_some();
                if let Some(i) = visible.get(self.list.selected) {
                    let x = self.model.extras[*i].clone();
                    self.draw_extra(p, input, detail, &x, toggle, actions)?;
                }
            }
        }
        let foot = Rect::new(rect.x, rect.bottom() - widgets::ROW_HEIGHT - 2.0, rect.w, widgets::ROW_HEIGHT);
        let hint = match self.tab {
            Tab::Installed => "j k move · / search · Esc closes · lazy.nvim owns the list, :Lazy has every command",
            Tab::Extras => "j k move · Enter turns an extra on or off (a restart applies it) · / search · Esc closes",
        };
        ui::label_centered_y(p, hint, rect.x + 12.0, &foot, cells(rect.w - 24.0), theme::ASH)?;
        Ok(close)
    }

    fn draw_plugin(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, pl: &Plugin, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        let cw = p.fonts.metrics().width;
        let cells = ((rect.w - 16.0) / cw).max(0.0) as usize;
        let mut y = rect.y;
        p.icon("pkg", rect.x, y + 2.0, 2, if pl.loaded { theme::SPECTRAL } else { theme::BONE_DIM })?;
        ui::label(p, &pl.name, rect.x + 28.0, y + 4.0, cells.saturating_sub(4), theme::SPECTRAL)?;
        y += widgets::ROW_HEIGHT + 6.0;
        if !pl.url.is_empty() {
            ui::label(p, &pl.url, rect.x, y, cells, theme::ASH)?;
            y += widgets::ROW_HEIGHT;
        }
        let state = format!(
            "{}{}{}{}",
            if pl.installed { "installed" } else { "not installed" },
            if !pl.enabled { " · disabled" } else if pl.loaded { " · loaded" } else { " · not loaded yet" },
            if pl.updates { " · update available" } else { "" },
            if pl.version.is_empty() || pl.version == "*" { String::new() } else { format!(" · {}", pl.version) }
        );
        ui::label(p, &state, rect.x, y, cells, if pl.updates { theme::GOLD } else { theme::BONE_DIM })?;
        y += widgets::ROW_HEIGHT + 6.0;
        if !pl.desc.is_empty() {
            for line in wrap(&pl.desc, cells) {
                ui::label(p, &line, rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            y += 6.0;
        }
        ui::label(p, "Loads when", rect.x, y, cells, theme::BONE_DIM)?;
        y += widgets::ROW_HEIGHT;
        for l in &pl.loads {
            for line in wrap(l, cells.saturating_sub(2)) {
                ui::label(p, &format!("  {line}"), rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
        }
        y += 6.0;
        if !pl.eq.is_empty() {
            ui::label(p, "Coming from VS Code, this covers", rect.x, y, cells, theme::BONE_DIM)?;
            y += widgets::ROW_HEIGHT;
            for e in &pl.eq {
                ui::label(p, &format!("  {e}"), rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            y += 6.0;
        }
        let mut bx = rect.x;
        if pl.updates {
            let r = Rect::new(bx, y, 110.0, 24.0);
            if widgets::button(p, input, r, "Update", true)? {
                actions.push(Action::Lua("require('nvs.bridge').plugin_action(...)".into(), vec![rmpv::Value::from("update"), rmpv::Value::from(pl.name.as_str())]));
                actions.push(Action::FocusGrid);
            }
            bx += 118.0;
        }
        if !pl.dir.is_empty() && pl.installed {
            let r = Rect::new(bx, y, 150.0, 24.0);
            if widgets::button(p, input, r, "Open its folder", false)? {
                actions.push(Action::Lua("vim.cmd.edit(vim.fn.fnameescape(...))".into(), vec![rmpv::Value::from(pl.dir.as_str())]));
                actions.push(Action::FocusGrid);
            }
        }
        Ok(())
    }

    fn draw_extra(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, x: &Extra, toggle_key: bool, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        let cw = p.fonts.metrics().width;
        let cells = ((rect.w - 16.0) / cw).max(0.0) as usize;
        let mut y = rect.y;
        p.icon("pkg", rect.x, y + 2.0, 2, if x.enabled { theme::SPECTRAL } else { theme::BONE_DIM })?;
        ui::label(p, &x.name, rect.x + 28.0, y + 4.0, cells.saturating_sub(4), theme::SPECTRAL)?;
        y += widgets::ROW_HEIGHT + 6.0;
        ui::label(p, &x.module, rect.x, y, cells, theme::ASH)?;
        y += widgets::ROW_HEIGHT;
        let state = format!(
            "{}{}{}",
            if x.enabled { "enabled" } else { "not enabled" },
            if x.recommended { " · recommended for this project" } else { "" },
            if !x.managed { " · turned on from the config files" } else { "" }
        );
        ui::label(p, &state, rect.x, y, cells, theme::BONE_DIM)?;
        y += widgets::ROW_HEIGHT + 6.0;
        if !x.desc.is_empty() {
            for line in wrap(&x.desc, cells) {
                ui::label(p, &line, rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            y += 6.0;
        }
        if !x.plugins.is_empty() {
            ui::label(p, "Plugins it brings", rect.x, y, cells, theme::BONE_DIM)?;
            y += widgets::ROW_HEIGHT;
            for line in wrap(&x.plugins.join(", "), cells.saturating_sub(2)) {
                ui::label(p, &format!("  {line}"), rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            y += 6.0;
        }
        let r = Rect::new(rect.x, y, 170.0, 24.0);
        let label = if x.enabled { "Disable extra" } else { "Enable extra" };
        let clicked = widgets::button(p, input, r, label, !x.enabled && x.managed)?;
        if !x.managed {
            ui::label(p, "Enabled from lua/config/lazy.lua; edit that file to turn it off.", r.right() + 10.0, y + 2.0, cells.saturating_sub(24), theme::ASH)?;
        } else if clicked || toggle_key {
            actions.push(Action::Lua("require('nvs.bridge').plugin_action(...)".into(), vec![rmpv::Value::from("toggle_extra"), rmpv::Value::from(x.module.as_str())]));
        }
        y += 30.0;
        ui::label(p, "Restart nvs.ide after changing extras; :LazyExtras is the same list inside Neovim.", rect.x, y, cells, theme::ASH)?;
        Ok(())
    }
}

/// Greedy word wrap to `width` cells.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(8);
    let mut lines = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        if !line.is_empty() && line.chars().count() + 1 + word.chars().count() > width {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}
