//! The command palette: Ctrl+Shift+P. Plain text finds shell and editor commands, `:` runs an
//! Ex command, `@` finds files, `/` searches the current buffer.

use crate::ui::widgets::{ListState, TextState};

use super::tasks::fuzzy;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PaletteSource {
    Shell,
    Ex,
    File,
    Line,
}

impl PaletteSource {
    pub fn tag(&self) -> &'static str {
        match self {
            PaletteSource::Shell => "shell",
            PaletteSource::Ex => "ex",
            PaletteSource::File => "file",
            PaletteSource::Line => "line",
        }
    }
}

#[derive(Clone, Debug)]
pub struct PaletteItem {
    pub title: String,
    pub source: PaletteSource,
    /// The VS Code key, if any.
    pub key: &'static str,
    /// The Vim way, if any.
    pub vim: &'static str,
    pub command: PaletteCommand,
}

#[derive(Clone, Debug)]
pub enum PaletteCommand {
    ToggleSidebar,
    TogglePanel,
    ShowView(super::View),
    ShowPanel(super::PanelTab),
    Ex(String),
    Keys(String),
    OpenFile(String),
    Stage(u32),
    Screen(super::Screen),
}

pub struct Palette {
    pub input: TextState,
    pub list: ListState,
    pub files: Vec<String>,
    pub files_cwd: Option<std::path::PathBuf>,
    /// Filtered items for the current query, with match positions.
    pub matches: Vec<(PaletteItem, Vec<usize>)>,
}

impl Palette {
    pub fn new(prefix: &str) -> Self {
        let mut input = TextState::default();
        input.set(prefix);
        Palette { input, list: ListState::default(), files: Vec::new(), files_cwd: None, matches: Vec::new() }
    }

    pub fn prefix(&self) -> Option<char> {
        self.input.text.chars().next().filter(|c| matches!(c, ':' | '@' | '/'))
    }

    pub fn query(&self) -> String {
        match self.prefix() {
            Some(_) => self.input.text.chars().skip(1).collect::<String>().trim().to_string(),
            None => self.input.text.trim().to_string(),
        }
    }

    pub fn footer(&self) -> String {
        match self.prefix() {
            Some(':') => "Command line. Enter runs it in Neovim.".into(),
            Some('@') => format!("{} files. Enter opens.", self.files.len()),
            Some('/') => "Search this file. Enter jumps, then n and N.".into(),
            _ => format!("{} commands. Start with : for Ex, @ for files, / to search.", self.matches.len()),
        }
    }

    /// Rebuild `matches` from the query.
    pub fn refilter(&mut self, commands: &[PaletteItem]) {
        let query = self.query();
        let mut scored: Vec<(i32, usize, PaletteItem, Vec<usize>)> = Vec::new();
        match self.prefix() {
            Some('@') => {
                for (i, file) in self.files.iter().enumerate() {
                    if let Some((score, hits)) = fuzzy(&query, file) {
                        scored.push((score, i, PaletteItem { title: file.clone(), source: PaletteSource::File, key: "", vim: "", command: PaletteCommand::OpenFile(file.clone()) }, hits));
                    }
                    if scored.len() > 2000 {
                        break;
                    }
                }
            }
            Some(':') => {
                if !query.is_empty() {
                    scored.push((0, 0, PaletteItem { title: format!("Run :{query}"), source: PaletteSource::Ex, key: "", vim: "", command: PaletteCommand::Ex(query.clone()) }, Vec::new()));
                }
                for (i, item) in commands.iter().enumerate().filter(|(_, c)| c.source == PaletteSource::Ex) {
                    if let Some((score, hits)) = fuzzy(&query, &item.title) {
                        scored.push((score + 1, i + 1, item.clone(), hits));
                    }
                }
            }
            Some('/') => {
                if !query.is_empty() {
                    scored.push((0, 0, PaletteItem { title: format!("Search for {query}"), source: PaletteSource::Line, key: "", vim: "/", command: PaletteCommand::Keys(format!("/{}<CR>", query.replace('<', "<lt>"))) }, Vec::new()));
                }
            }
            _ => {
                for (i, item) in commands.iter().enumerate().filter(|(_, c)| c.source != PaletteSource::Ex) {
                    if let Some((score, hits)) = fuzzy(&query, &item.title) {
                        scored.push((score, i, item.clone(), hits));
                    }
                }
            }
        }
        // Best score first; ties keep declaration order (an empty query lists commands as written).
        scored.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        scored.truncate(200);
        self.matches = scored.into_iter().map(|(_, _, item, hits)| (item, hits)).collect();
        self.list.selected = self.list.selected.min(self.matches.len().saturating_sub(1));
        self.list.scroll = 0;
    }
}
