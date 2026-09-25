//! One Neovim grid ("window" in multigrid terms) and how its rows become renderable lines.
//! Ported from Neovide's src/editor/window.rs (MIT, LICENSE-NEOVIDE). Instead of streaming
//! draw commands to a renderer that keeps per-window surfaces, the shell asks a window for a
//! snapshot of its lines whenever Neovim flushes.

use std::{collections::HashMap, ops::Range, sync::Arc};

use crate::bridge::GridLineCell;

use super::{grid::CharacterGrid, style::Style, AnchorInfo};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum WindowType {
    Editor,
    Message { scrolled: bool },
}

/// A run of cells that share one style. `text` is the concatenated cell text; `words`
/// split it at whitespace so the shaper can cache short strings and align each to its cell.
#[derive(Debug, Clone, PartialEq)]
pub struct LineFragment {
    pub cells: Range<u32>,
    pub style: Option<Arc<Style>>,
    pub words: Vec<Word>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Word {
    pub text: String,
    /// The cell (relative to the fragment start) where this word begins.
    pub cell: u32,
    /// Byte length of each grapheme cluster; 0 marks the empty right half of a double-width char.
    pub cluster_sizes: Vec<u8>,
}

impl Word {
    /// (cell offset within the word, cluster text) pairs.
    pub fn clusters(&self) -> impl Iterator<Item = (usize, &str)> + '_ {
        let mut pos = 0usize;
        self.cluster_sizes.iter().enumerate().filter_map(move |(cell, size)| {
            if *size == 0 {
                return None;
            }
            let start = pos;
            pos += *size as usize;
            Some((cell, &self.text[start..pos]))
        })
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Line {
    pub fragments: Vec<LineFragment>,
}

pub struct Window {
    pub grid_id: u64,
    pub grid: CharacterGrid,
    pub window_type: WindowType,
    pub anchor_info: Option<AnchorInfo>,
    /// Position in grid-1 cells, resolved (floats already offset by their anchor grid).
    pub grid_position: (f64, f64),
    pub hidden: bool,
    /// Rows in the top and bottom margins that do not scroll (winbar, float borders).
    pub viewport_margins: (u64, u64),
}

impl Window {
    pub fn new(grid_id: u64, window_type: WindowType, anchor_info: Option<AnchorInfo>, grid_position: (f64, f64), grid_size: (u64, u64)) -> Window {
        Window {
            grid_id,
            grid: CharacterGrid::new((grid_size.0 as usize, grid_size.1 as usize)),
            window_type,
            anchor_info,
            grid_position,
            hidden: false,
            viewport_margins: (0, 0),
        }
    }

    pub fn get_width(&self) -> u64 {
        self.grid.width as u64
    }

    pub fn get_height(&self) -> u64 {
        self.grid.height as u64
    }

    /// Text, style and double-width flag of a cell, for the cursor.
    pub fn get_cursor_grid_cell(&self, left: u64, top: u64) -> (String, Option<Arc<Style>>, bool) {
        let cell = self
            .grid
            .get_cell(left as usize, top as usize)
            .map_or((" ".to_string(), None), |(text, style)| (text.clone(), style.clone()));
        let double_width = self.grid.get_cell(left as usize + 1, top as usize).map(|(text, _)| text.is_empty()).unwrap_or(false);
        (cell.0, cell.1, double_width)
    }

    pub fn position(&mut self, anchor_info: Option<AnchorInfo>, grid_size: (u64, u64), grid_position: (f64, f64)) {
        self.grid.resize((grid_size.0 as usize, grid_size.1 as usize));
        self.anchor_info = anchor_info;
        self.grid_position = grid_position;
    }

    pub fn resize(&mut self, new_size: (u64, u64)) {
        self.grid.resize((new_size.0 as usize, new_size.1 as usize));
    }

    fn modify_grid(&mut self, row: usize, column: &mut usize, cell: GridLineCell, styles: &HashMap<u64, Arc<Style>>, previous_style: &mut Option<Arc<Style>>) {
        let style = match cell.highlight_id {
            Some(0) => None,
            Some(id) => styles.get(&id).cloned(),
            None => previous_style.clone(),
        };
        let text = cell.text;
        if let Some(times) = cell.repeat {
            // Zero repeats mark "rest of line is empty" for the TUI; nothing to draw.
            if times == 0 {
                return;
            }
            for _ in 0..times.saturating_sub(1) {
                if let Some(c) = self.grid.get_cell_mut(*column, row) {
                    *c = (text.clone(), style.clone());
                }
                *column += 1;
            }
        }
        if let Some(c) = self.grid.get_cell_mut(*column, row) {
            *c = (text, style.clone());
        }
        *column += 1;
        *previous_style = style;
    }

    pub fn draw_grid_line(&mut self, row: u64, column_start: u64, cells: Vec<GridLineCell>, styles: &HashMap<u64, Arc<Style>>) {
        let row = row as usize;
        if row >= self.grid.height {
            log::warn!("grid_line out of bounds: grid {} row {row}", self.grid_id);
            return;
        }
        let mut previous_style = None;
        let mut column = column_start as usize;
        for cell in cells {
            self.modify_grid(row, &mut column, cell, styles, &mut previous_style);
        }
    }

    pub fn scroll_region(&mut self, top: u64, bottom: u64, left: u64, right: u64, rows: i64, cols: i64) {
        self.grid.scroll_region(top as usize, bottom as usize, left as usize, right as usize, rows as isize, cols as isize);
    }

    pub fn clear(&mut self) {
        self.grid.clear();
    }

    /// Build one style-run fragment starting at `start`; returns the next start.
    fn build_line_fragment(&self, row: &[super::grid::GridCell], start: usize) -> (usize, LineFragment) {
        let (_, style) = &row[start];
        let mut width = 0u32;
        let mut words = Vec::new();
        let mut current = Word { text: String::new(), cell: 0, cluster_sizes: Vec::new() };

        for (cluster, cell_style) in row.iter().take(self.grid.width).skip(start) {
            if style != cell_style {
                break;
            }
            width += 1;
            let cluster: &str = if cluster.len() > 255 { " " } else { cluster };
            if cluster.is_empty() {
                // Right half of a double-width char: part of the current word with size 0.
                if !current.cluster_sizes.is_empty() {
                    current.cluster_sizes.push(0);
                }
                continue;
            }
            let is_whitespace = cluster.chars().next().is_some_and(char::is_whitespace);
            if is_whitespace {
                if !current.cluster_sizes.is_empty() {
                    words.push(std::mem::replace(&mut current, Word { text: String::new(), cell: 0, cluster_sizes: Vec::new() }));
                }
            } else {
                if current.cluster_sizes.is_empty() {
                    current.cell = width - 1;
                }
                current.text.push_str(cluster);
                current.cluster_sizes.push(cluster.len() as u8);
            }
        }
        if !current.cluster_sizes.is_empty() {
            words.push(current);
        }
        (start + width as usize, LineFragment { cells: start as u32..start as u32 + width, style: style.clone(), words })
    }

    pub fn snapshot_line(&self, row_index: usize) -> Line {
        let Some(row) = self.grid.row(row_index) else { return Line::default() };
        let mut start = 0;
        let mut fragments = Vec::new();
        while start < self.grid.width {
            let (next, fragment) = self.build_line_fragment(row, start);
            start = next;
            fragments.push(fragment);
        }
        Line { fragments }
    }

    pub fn snapshot_lines(&self) -> Vec<Line> {
        (0..self.grid.height).map(|row| self.snapshot_line(row)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::Rgba;
    use crate::editor::style::Colors;

    fn style(r: f32) -> Option<Arc<Style>> {
        Some(Arc::new(Style::new(Colors::new(Some(Rgba::new(r, 0.0, 0.0, 1.0)), None, None))))
    }

    fn window(rows: &[&[(&str, Option<Arc<Style>>)]]) -> Window {
        let mut w = Window::new(1, WindowType::Editor, None, (0.0, 0.0), (rows[0].len() as u64, rows.len() as u64));
        for (y, row) in rows.iter().enumerate() {
            for (x, (text, s)) in row.iter().enumerate() {
                *w.grid.get_cell_mut(x, y).unwrap() = (text.to_string(), s.clone());
            }
        }
        w
    }

    #[test]
    fn fragments_split_on_style_and_words_on_whitespace() {
        let a = style(0.1);
        let b = style(0.2);
        let w = window(&[&[("f", a.clone()), ("o", a.clone()), (" ", a.clone()), ("x", b.clone()), ("y", b.clone())]]);
        let line = w.snapshot_line(0);
        assert_eq!(line.fragments.len(), 2);
        assert_eq!(line.fragments[0].cells, 0..3);
        assert_eq!(line.fragments[0].words.len(), 1);
        assert_eq!(line.fragments[0].words[0].text, "fo");
        assert_eq!(line.fragments[1].cells, 3..5);
        assert_eq!(line.fragments[1].words[0].text, "xy");
        assert_eq!(line.fragments[1].words[0].cell, 0);
    }

    #[test]
    fn double_width_cells_join_their_word() {
        let a = style(0.1);
        let w = window(&[&[("a", a.clone()), ("一", a.clone()), ("", a.clone()), ("b", a.clone())]]);
        let line = w.snapshot_line(0);
        let word = &line.fragments[0].words[0];
        assert_eq!(word.text, "a一b");
        assert_eq!(word.cluster_sizes, vec![1, 3, 0, 1]);
        let clusters: Vec<_> = word.clusters().collect();
        assert_eq!(clusters, vec![(0, "a"), (1, "一"), (3, "b")]);
    }

    #[test]
    fn grid_line_repeat_and_inherit() {
        let mut w = Window::new(1, WindowType::Editor, None, (0.0, 0.0), (6, 1));
        let mut styles = HashMap::new();
        styles.insert(7u64, Arc::new(Style::default()));
        w.draw_grid_line(
            0,
            0,
            vec![
                GridLineCell { text: "a".into(), highlight_id: Some(7), repeat: None },
                GridLineCell { text: "b".into(), highlight_id: None, repeat: Some(3) },
                GridLineCell { text: " ".into(), highlight_id: Some(0), repeat: Some(0) },
            ],
            &styles,
        );
        assert_eq!(w.grid.get_cell(3, 0).unwrap().0, "b");
        assert!(w.grid.get_cell(3, 0).unwrap().1.is_some());
        assert_eq!(w.grid.get_cell(4, 0).unwrap().0, " ");
    }
}
