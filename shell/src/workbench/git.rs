//! The Source control view: staged and unstaged changes, stage/unstage, commit.

use crate::ui::widgets::{ListState, TextState};

use super::tasks::GitStatus;

#[derive(Default)]
pub struct GitView {
    pub status: GitStatus,
    pub message: TextState,
    pub list: ListState,
    pub editing: bool,
    pub busy: bool,
    pub last_error: Option<String>,
    pub loaded: bool,
}

pub enum GitRow {
    Header(&'static str, usize),
    Staged(usize),
    Unstaged(usize),
}

impl GitView {
    pub fn rows(&self) -> Vec<GitRow> {
        let mut rows = vec![GitRow::Header("Staged", self.status.staged.len())];
        rows.extend((0..self.status.staged.len()).map(GitRow::Staged));
        rows.push(GitRow::Header("Changes", self.status.unstaged.len()));
        rows.extend((0..self.status.unstaged.len()).map(GitRow::Unstaged));
        rows
    }
}
