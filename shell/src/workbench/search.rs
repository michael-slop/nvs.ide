//! The Search view: a query box over ripgrep, results grouped by file.

use crate::ui::widgets::{ListState, TextState};

use super::tasks::SearchHit;

#[derive(Default)]
pub struct SearchView {
    pub query: TextState,
    pub list: ListState,
    pub hits: Vec<SearchHit>,
    pub error: Option<String>,
    /// Generation of the last request; stale results are dropped.
    pub generation: u64,
    pub searching: bool,
    /// True while the query box has the keyboard.
    pub editing: bool,
}

pub enum SearchRow {
    File(String),
    Hit(usize),
}

impl SearchView {
    /// Rows to draw: a header per file, then its hits.
    pub fn rows(&self) -> Vec<SearchRow> {
        let mut rows = Vec::new();
        let mut last_file: Option<&str> = None;
        for (i, hit) in self.hits.iter().enumerate() {
            if last_file != Some(hit.file.as_str()) {
                rows.push(SearchRow::File(hit.file.clone()));
                last_file = Some(hit.file.as_str());
            }
            rows.push(SearchRow::Hit(i));
        }
        rows
    }

    pub fn file_count(&self) -> usize {
        let mut files: Vec<&str> = self.hits.iter().map(|h| h.file.as_str()).collect();
        files.dedup();
        files.len()
    }
}
