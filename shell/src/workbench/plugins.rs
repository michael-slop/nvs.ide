//! The Plugins screen: lazy.nvim's plugin list and LazyVim's extras (from
//! `runtime/lua/nvs/plugins.lua`) and VS Code extensions from Open VSX (from
//! `runtime/lua/nvs/vsx.lua`; the contract is docs/extensions.md), all over the bridge.

use std::collections::HashMap;

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

// VS Code extensions (docs/extensions.md).

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxModel {
    #[serde(default)]
    pub installed: Vec<VsxEntry>,
    #[serde(default)]
    pub status: VsxStatus,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxStatus {
    #[serde(default)]
    pub host: VsxHost,
    #[serde(default)]
    pub registry: String,
    #[serde(default)]
    pub node_version: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxHost {
    #[serde(default)]
    pub running: bool,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub node: Option<String>,
    #[serde(default)]
    pub extensions: u32,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxEntry {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub namespace: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default, rename = "displayName")]
    pub display_name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub tier: String,
    #[serde(default)]
    pub why: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub main: Option<String>,
    #[serde(default)]
    pub server: Option<VsxServer>,
    #[serde(default)]
    pub languages: Vec<String>,
    #[serde(default)]
    pub contributes: VsxContributes,
    #[serde(default)]
    pub converted: VsxConverted,
    #[serde(default)]
    pub alt: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxServer {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub lspconfig: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxContributes {
    #[serde(default)]
    pub themes: Vec<String>,
    #[serde(default)]
    pub snippets: u32,
    #[serde(default)]
    pub languages: u32,
    #[serde(default)]
    pub grammars: u32,
    #[serde(default)]
    pub commands: u32,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxConverted {
    #[serde(default)]
    pub colors: Vec<String>,
    #[serde(default)]
    pub filetypes: Vec<String>,
    #[serde(default)]
    pub snippets: bool,
    #[serde(default)]
    pub skipped: Vec<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxSearch {
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub results: Vec<VsxResult>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxResult {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub namespace: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "displayName")]
    pub display_name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub downloads: u64,
    #[serde(default)]
    pub rating: Option<f64>,
    #[serde(default)]
    pub installed: bool,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct VsxProgress {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    pub message: String,
}

/// The tier sentence from docs/extensions.md.
fn tier_sentence(tier: &str) -> &'static str {
    match tier {
        "t1" => "Tier 1, declarative: converted when it was installed (themes, snippets, language ids). Nothing runs afterwards.",
        "lsp" => "Native LSP: the language server it ships is started by Neovim's own LSP client. The extension's client code never runs.",
        "t2" => "Tier 2: runs in the extension host, a Node program Neovim talks to like a language server.",
        "t3" => "Tier 3: needs webviews, which nvs.ide does not have. Installed but inert.",
        _ => "",
    }
}

fn tier_tag(tier: &str) -> &'static str {
    match tier {
        "t1" => "THEME/SNIPPETS",
        "lsp" => "NATIVE LSP",
        "t2" => "EXT HOST",
        "t3" => "NEEDS WEBVIEWS",
        _ => "VSX",
    }
}

fn tier_color(tier: &str, enabled: bool) -> crate::color::Rgba {
    if !enabled {
        return theme::ASH;
    }
    match tier {
        "t1" => theme::CORPSE,
        "lsp" => theme::NECROTIC,
        "t2" => theme::GOLD,
        "t3" => theme::ASH,
        _ => theme::BONE_DIM,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tab {
    Installed,
    Extras,
    Browse,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Focus {
    Search,
    List,
}

/// What the Installed list shows in one row.
enum InstalledRow {
    Plugin(usize),
    Vsx(usize),
}

pub struct PluginsScreen {
    pub model: PluginsModel,
    pub vsx: VsxModel,
    pub search: Option<VsxSearch>,
    pub progress: HashMap<String, VsxProgress>,
    pub tab: Tab,
    filter: TextState,
    browse_query: TextState,
    list: ListState,
    browse_list: ListState,
    focus: Focus,
    searching: bool,
}

impl Default for PluginsScreen {
    fn default() -> Self {
        PluginsScreen {
            model: PluginsModel::default(),
            vsx: VsxModel::default(),
            search: None,
            progress: HashMap::new(),
            tab: Tab::Installed,
            filter: TextState::default(),
            browse_query: TextState::default(),
            list: ListState::default(),
            browse_list: ListState::default(),
            focus: Focus::List,
            searching: false,
        }
    }
}

fn vsx_lua(action: &str, args: Vec<rmpv::Value>) -> Action {
    let mut all = vec![rmpv::Value::from(action)];
    all.extend(args);
    Action::Lua("require('nvs.bridge').vsx(...)".into(), all)
}

impl PluginsScreen {
    pub fn set_model(&mut self, model: PluginsModel) {
        self.model = model;
    }

    /// Open the Browse tab with the search box ready to type into.
    pub fn show_browse(&mut self) {
        self.tab = Tab::Browse;
        self.focus = Focus::Search;
    }

    pub fn set_vsx(&mut self, vsx: VsxModel) {
        // A finished install clears its progress line.
        for e in &vsx.installed {
            if let Some(p) = self.progress.get(&e.id) {
                if p.stage == "done" {
                    self.progress.remove(&e.id);
                }
            }
        }
        self.vsx = vsx;
        if let Some(s) = &mut self.search {
            for r in &mut s.results {
                r.installed = self.vsx.installed.iter().any(|e| e.id == r.id);
            }
        }
    }

    pub fn set_search(&mut self, search: VsxSearch) {
        self.searching = false;
        self.browse_list = ListState::default();
        self.search = Some(search);
    }

    pub fn set_progress(&mut self, p: VsxProgress) {
        self.progress.insert(p.id.clone(), p);
    }

    fn visible_plugins(&self) -> Vec<InstalledRow> {
        let q = self.filter.text.trim().to_lowercase();
        let mut rows: Vec<InstalledRow> = self
            .vsx
            .installed
            .iter()
            .enumerate()
            .filter(|(_, e)| q.is_empty() || format!("{} {} {} {}", e.display_name, e.id, e.description, e.alt.clone().unwrap_or_default()).to_lowercase().contains(&q))
            .map(|(i, _)| InstalledRow::Vsx(i))
            .collect();
        rows.extend(
            self.model
                .plugins
                .iter()
                .enumerate()
                .filter(|(_, p)| q.is_empty() || format!("{} {} {}", p.name, p.desc, p.eq.join(" ")).to_lowercase().contains(&q))
                .map(|(i, _)| InstalledRow::Plugin(i)),
        );
        rows
    }

    fn visible_extras(&self) -> Vec<usize> {
        let q = self.filter.text.trim().to_lowercase();
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
        let n_installed = self.model.plugins.iter().filter(|p| p.installed).count() + self.vsx.installed.len();
        let n_extras = self.model.extras.iter().filter(|x| x.enabled).count();
        let tabs = [(Tab::Installed, format!("Installed {n_installed}")), (Tab::Extras, format!("Extras {n_extras} on")), (Tab::Browse, "Browse Open VSX".to_string())];
        let mut x = bar.x;
        for (tab, title) in tabs {
            let w = title.chars().count() as f32 * cw + 20.0;
            let r = Rect::new(x, bar.y, w, bar.h);
            if widgets::button(p, input, r, &title, self.tab == tab)? && self.tab != tab {
                self.tab = tab;
                self.list = ListState::default();
                self.focus = if tab == Tab::Browse && self.search.is_none() { Focus::Search } else { Focus::List };
            }
            x += w + 6.0;
        }
        let update_w = 120.0;
        let lazy_w = 110.0;
        // The lazy.nvim buttons belong to the Installed and Extras tabs; Browse gets the width.
        let buttons_w = if self.tab == Tab::Browse { 0.0 } else { update_w + lazy_w + 16.0 };
        let field = Rect::new(x + 6.0, bar.y, (bar.right() - x - 6.0 - buttons_w).max(120.0), bar.h);
        if self.tab == Tab::Browse {
            let resp = widgets::text_field(p, input, field, &mut self.browse_query, "Search Open VSX for an extension you miss (Enter)", self.focus == Focus::Search)?;
            if resp.clicked {
                self.focus = Focus::Search;
            }
            if resp.submitted {
                let q = self.browse_query.text.trim().to_string();
                if !q.is_empty() {
                    self.searching = true;
                    actions.push(vsx_lua("search", vec![rmpv::Value::from(q.as_str())]));
                }
                self.focus = Focus::List;
            }
            if resp.down {
                self.focus = Focus::List;
            }
            if resp.cancelled {
                if self.browse_query.text.is_empty() {
                    close = true;
                } else {
                    self.browse_query.set("");
                }
            }
        } else {
            let resp = widgets::text_field(p, input, field, &mut self.filter, "Search plugins, or name what you used in VS Code", self.focus == Focus::Search)?;
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
                if self.filter.text.is_empty() {
                    self.focus = Focus::List;
                } else {
                    self.filter.set("");
                }
            }
        }
        if self.tab != Tab::Browse {
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
        }

        let body_y = bar.bottom() + 10.0;
        let body_h = (rect.bottom() - body_y - widgets::ROW_HEIGHT - 12.0).max(0.0);
        let list_w = ((rect.w - 24.0) * 0.45).clamp(200.0, 420.0);
        let list_rect = Rect::new(rect.x + 12.0, body_y, list_w, body_h);
        let detail = Rect::new(list_rect.right() + 16.0, body_y, (rect.right() - list_rect.right() - 28.0).max(100.0), body_h);
        p.rect(detail.x - 8.0, body_y, 1.0, body_h, theme::STONE);

        let focused = self.focus == Focus::List;
        for e in &input.events {
            if let ui::UiEvent::PointerDown { x, y, .. } = e {
                if list_rect.contains(*x, *y) {
                    self.focus = Focus::List;
                }
            }
        }
        match self.tab {
            Tab::Installed => {
                let visible = self.visible_plugins();
                let rows: Vec<Row> = visible
                    .iter()
                    .map(|r| match r {
                        InstalledRow::Plugin(i) => {
                            let pl = &self.model.plugins[*i];
                            let mut row = Row::new(pl.name.clone());
                            row.icon = Some(("pkg", if !pl.enabled { theme::ASH } else if pl.loaded { theme::SPECTRAL } else { theme::BONE_DIM }));
                            row.right = Some(if pl.updates { "update".into() } else if !pl.enabled { "off".into() } else if pl.loaded { "loaded".into() } else if pl.lazy { "lazy".into() } else { String::new() });
                            row.right_color = if pl.updates { theme::GOLD } else { theme::ASH };
                            if pl.dep {
                                row.color = theme::BONE_DIM;
                            }
                            row
                        }
                        InstalledRow::Vsx(i) => {
                            let e = &self.vsx.installed[*i];
                            let mut row = Row::new(if e.display_name.is_empty() { e.id.clone() } else { e.display_name.clone() });
                            row.icon = Some(("pkg", tier_color(&e.tier, e.enabled)));
                            row.right = Some(if !e.enabled { "off".into() } else { tier_tag(&e.tier).to_lowercase() });
                            row.right_color = tier_color(&e.tier, e.enabled);
                            row
                        }
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
                    if self.filter.text.is_empty() {
                        close = true;
                    } else {
                        self.filter.set("");
                    }
                }
                match visible.get(self.list.selected) {
                    Some(InstalledRow::Plugin(i)) => {
                        let pl = self.model.plugins[*i].clone();
                        self.draw_plugin(p, input, detail, &pl, actions)?;
                    }
                    Some(InstalledRow::Vsx(i)) => {
                        let e = self.vsx.installed[*i].clone();
                        self.draw_vsx_entry(p, input, detail, &e, actions)?;
                    }
                    None => {}
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
                    if self.filter.text.is_empty() {
                        close = true;
                    } else {
                        self.filter.set("");
                    }
                }
                let toggle = lr.activated.is_some();
                if let Some(i) = visible.get(self.list.selected) {
                    let x = self.model.extras[*i].clone();
                    self.draw_extra(p, input, detail, &x, toggle, actions)?;
                }
            }
            Tab::Browse => {
                let results: Vec<VsxResult> = self.search.as_ref().map(|s| s.results.clone()).unwrap_or_default();
                let rows: Vec<Row> = results
                    .iter()
                    .map(|r| {
                        let mut row = Row::new(if r.display_name.is_empty() { r.id.clone() } else { r.display_name.clone() });
                        row.icon = Some(("pkg", if r.installed { theme::SPECTRAL } else { theme::CORPSE }));
                        row.right = Some(if r.installed { "installed".into() } else { downloads_text(r.downloads) });
                        row.right_color = if r.installed { theme::SPECTRAL } else { theme::ASH };
                        row
                    })
                    .collect();
                if rows.is_empty() {
                    let note = if self.searching {
                        "Searching Open VSX…".to_string()
                    } else if let Some(s) = &self.search {
                        s.error.clone().unwrap_or_else(|| format!("Nothing on Open VSX matches \"{}\".", s.query))
                    } else {
                        "Type what you used in VS Code and press Enter. Themes and snippets install as they are; extensions that ship a language server run natively; the rest run in the extension host.".to_string()
                    };
                    let mut y = list_rect.y + 4.0;
                    for line in wrap(&note, cells(list_rect.w - 16.0)) {
                        ui::label(p, &line, list_rect.x + 8.0, y, cells(list_rect.w - 16.0), theme::ASH)?;
                        y += widgets::ROW_HEIGHT;
                    }
                }
                let lr = widgets::list(p, input, list_rect, &mut self.browse_list, &rows, focused)?;
                if lr.slash {
                    self.focus = Focus::Search;
                }
                if lr.escape {
                    close = true;
                }
                let install = lr.activated.is_some();
                if let Some(r) = results.get(self.browse_list.selected) {
                    let r = r.clone();
                    self.draw_vsx_result(p, input, detail, &r, install, actions)?;
                }
            }
        }
        let foot = Rect::new(rect.x, rect.bottom() - widgets::ROW_HEIGHT - 2.0, rect.w, widgets::ROW_HEIGHT);
        let host = &self.vsx.status.host;
        let host_text = match host.mode.as_str() {
            "never" => "extension host off".to_string(),
            _ if host.running => "extension host running".to_string(),
            _ if host.node.is_none() && !self.vsx.installed.is_empty() => "extension host: node not found".to_string(),
            _ => "extension host idle".to_string(),
        };
        let hint = match self.tab {
            Tab::Installed => format!("j k move · / search · Esc closes · {host_text}"),
            Tab::Extras => "j k move · Enter turns an extra on or off (a restart applies it) · / search · Esc closes".to_string(),
            Tab::Browse => format!("/ search · j k move · Enter installs · Esc closes · registry {}", if self.vsx.status.registry.is_empty() { "open-vsx.org" } else { self.vsx.status.registry.as_str() }),
        };
        ui::label_centered_y(p, &hint, rect.x + 12.0, &foot, cells(rect.w - 24.0), theme::ASH)?;
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

    /// An installed VS Code extension: how it runs, what was converted, the native alternative.
    fn draw_vsx_entry(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, e: &VsxEntry, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        let cw = p.fonts.metrics().width;
        let cells = ((rect.w - 16.0) / cw).max(0.0) as usize;
        let mut y = rect.y;
        p.icon("pkg", rect.x, y + 2.0, 2, tier_color(&e.tier, e.enabled))?;
        ui::label(p, if e.display_name.is_empty() { &e.id } else { &e.display_name }, rect.x + 28.0, y + 4.0, cells.saturating_sub(4), theme::SPECTRAL)?;
        y += widgets::ROW_HEIGHT + 6.0;
        ui::label(p, &format!("{}  ·  {}  ·  VS Code extension from Open VSX", e.id, e.version), rect.x, y, cells, theme::ASH)?;
        y += widgets::ROW_HEIGHT;
        let state = format!("{}{}{}", tier_tag(&e.tier), if e.enabled { "" } else { " · disabled" }, if e.license.is_empty() { String::new() } else { format!(" · {}", e.license) });
        ui::label(p, &state, rect.x, y, cells, tier_color(&e.tier, e.enabled))?;
        y += widgets::ROW_HEIGHT + 6.0;
        if !e.description.is_empty() {
            for line in wrap(&e.description, cells) {
                ui::label(p, &line, rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            y += 6.0;
        }
        ui::label(p, "How it runs", rect.x, y, cells, theme::BONE_DIM)?;
        y += widgets::ROW_HEIGHT;
        let mut how = tier_sentence(&e.tier).to_string();
        if !e.why.is_empty() {
            how = format!("{how} ({})", e.why);
        }
        for line in wrap(&how, cells.saturating_sub(2)) {
            ui::label(p, &format!("  {line}"), rect.x, y, cells, theme::BONE)?;
            y += widgets::ROW_HEIGHT;
        }
        if let Some(s) = &e.server {
            let name = s.lspconfig.clone().map(|n| format!("as nvim-lspconfig's {n}")).unwrap_or_else(|| "with its own defaults".into());
            for line in wrap(&format!("Server: {} {}", s.path, name), cells.saturating_sub(2)) {
                ui::label(p, &format!("  {line}"), rect.x, y, cells, theme::BONE_DIM)?;
                y += widgets::ROW_HEIGHT;
            }
        }
        if e.tier == "t2" && self.vsx.status.host.mode == "never" {
            ui::label(p, "  The extension host is set to Never in Settings > Plugins, so this does not run.", rect.x, y, cells, theme::GOLD)?;
            y += widgets::ROW_HEIGHT;
        }
        y += 6.0;
        let mut converted: Vec<String> = Vec::new();
        if !e.converted.colors.is_empty() {
            converted.push(format!("colour schemes: {} (:colorscheme, or Settings > Appearance)", e.converted.colors.join(", ")));
        }
        if e.converted.snippets {
            converted.push("snippets: loaded by blink.cmp after a restart".into());
        }
        if !e.converted.filetypes.is_empty() {
            converted.push(format!("file types: {}", e.converted.filetypes.join(", ")));
        }
        if !converted.is_empty() || !e.converted.skipped.is_empty() {
            ui::label(p, "Converted", rect.x, y, cells, theme::BONE_DIM)?;
            y += widgets::ROW_HEIGHT;
            for c in &converted {
                for line in wrap(c, cells.saturating_sub(2)) {
                    ui::label(p, &format!("  {line}"), rect.x, y, cells, theme::BONE)?;
                    y += widgets::ROW_HEIGHT;
                }
            }
            for s in &e.converted.skipped {
                for line in wrap(&format!("skipped {s}"), cells.saturating_sub(2)) {
                    ui::label(p, &format!("  {line}"), rect.x, y, cells, theme::ASH)?;
                    y += widgets::ROW_HEIGHT;
                }
            }
            y += 6.0;
        }
        if let Some(alt) = &e.alt {
            ui::label(p, "Neovim-native alternative", rect.x, y, cells, theme::BONE_DIM)?;
            y += widgets::ROW_HEIGHT;
            for line in wrap(&format!("{alt} does this without the extension host; LazyVim ships it or its extra."), cells.saturating_sub(2)) {
                ui::label(p, &format!("  {line}"), rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            y += 6.0;
        }
        if let Some(pr) = self.progress.get(&e.id) {
            ui::label(p, &format!("{}: {}", pr.stage, pr.message), rect.x, y, cells, if pr.stage == "error" { theme::VISCERA } else { theme::GOLD })?;
            y += widgets::ROW_HEIGHT + 6.0;
        }
        let toggle = Rect::new(rect.x, y, 120.0, 24.0);
        if widgets::button(p, input, toggle, if e.enabled { "Disable" } else { "Enable" }, !e.enabled)? {
            actions.push(vsx_lua("enable", vec![rmpv::Value::from(e.id.as_str()), rmpv::Value::Boolean(!e.enabled)]));
        }
        let un = Rect::new(toggle.right() + 8.0, y, 120.0, 24.0);
        if widgets::button(p, input, un, "Uninstall", false)? {
            actions.push(vsx_lua("uninstall", vec![rmpv::Value::from(e.id.as_str())]));
        }
        Ok(())
    }

    /// A search result from Open VSX.
    fn draw_vsx_result(&mut self, p: &mut Painter, input: &UiInput, rect: Rect, r: &VsxResult, install_key: bool, actions: &mut Vec<Action>) -> Result<(), AtlasFull> {
        let cw = p.fonts.metrics().width;
        let cells = ((rect.w - 16.0) / cw).max(0.0) as usize;
        let mut y = rect.y;
        p.icon("pkg", rect.x, y + 2.0, 2, theme::CORPSE)?;
        ui::label(p, if r.display_name.is_empty() { &r.id } else { &r.display_name }, rect.x + 28.0, y + 4.0, cells.saturating_sub(4), theme::SPECTRAL)?;
        y += widgets::ROW_HEIGHT + 6.0;
        ui::label(p, &format!("{}  ·  {}  ·  {}{}", r.id, r.version, downloads_text(r.downloads), r.rating.map(|x| format!("  ·  rated {x:.1}")).unwrap_or_default()), rect.x, y, cells, theme::ASH)?;
        y += widgets::ROW_HEIGHT + 6.0;
        if !r.description.is_empty() {
            for line in wrap(&r.description, cells) {
                ui::label(p, &line, rect.x, y, cells, theme::BONE)?;
                y += widgets::ROW_HEIGHT;
            }
            y += 6.0;
        }
        for line in wrap("What happens at install: the package is downloaded from Open VSX and its checksum checked; themes, snippets and file types are converted; an extension that ships a language server is run by Neovim's LSP client; other code runs in the extension host; webview extensions are installed but inert. The Installed tab then says which.", cells) {
            ui::label(p, &line, rect.x, y, cells, theme::BONE_DIM)?;
            y += widgets::ROW_HEIGHT;
        }
        y += 6.0;
        if let Some(pr) = self.progress.get(&r.id) {
            ui::label(p, &format!("{}: {}", pr.stage, pr.message), rect.x, y, cells, if pr.stage == "error" { theme::VISCERA } else { theme::GOLD })?;
            y += widgets::ROW_HEIGHT + 6.0;
        }
        let busy = self.progress.get(&r.id).map(|p| p.stage != "done" && p.stage != "error").unwrap_or(false);
        let btn = Rect::new(rect.x, y, 140.0, 24.0);
        if r.installed {
            ui::label_centered_y(p, "Installed. See the Installed tab.", rect.x, &btn, cells, theme::SPECTRAL)?;
        } else if busy {
            ui::label_centered_y(p, "Installing…", rect.x, &btn, cells, theme::GOLD)?;
        } else if widgets::button(p, input, btn, "Install", true)? || install_key {
            self.progress.insert(r.id.clone(), VsxProgress { id: r.id.clone(), stage: "download".into(), message: "starting".into() });
            actions.push(vsx_lua("install", vec![rmpv::Value::from(r.id.as_str())]));
        }
        Ok(())
    }
}

fn downloads_text(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M downloads", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{}k downloads", n / 1_000)
    } else {
        format!("{n} downloads")
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
