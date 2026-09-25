//! A grid of cells: the text and style Neovim put in each one.
//! Ported from Neovide's src/editor/grid.rs (MIT, LICENSE-NEOVIDE); the ring buffer became a
//! VecDeque, whose rotate is the same O(rows) pointer move.

use std::{collections::VecDeque, sync::Arc};

use super::style::Style;

pub type GridCell = (String, Option<Arc<Style>>);

fn default_cell() -> GridCell {
    (" ".to_owned(), None)
}

#[derive(Clone)]
struct GridLine {
    cells: Vec<GridCell>,
}

impl GridLine {
    fn new(length: usize) -> Self {
        GridLine { cells: vec![default_cell(); length] }
    }
}

pub struct CharacterGrid {
    pub width: usize,
    pub height: usize,
    lines: VecDeque<GridLine>,
}

impl CharacterGrid {
    pub fn new((width, height): (usize, usize)) -> Self {
        let mut lines = VecDeque::with_capacity(height);
        for _ in 0..height {
            lines.push_back(GridLine::new(width));
        }
        CharacterGrid { width, height, lines }
    }

    pub fn resize(&mut self, (width, height): (usize, usize)) {
        self.lines.resize(height, GridLine::new(width));
        for line in &mut self.lines {
            line.cells.resize(width, default_cell());
        }
        self.width = width;
        self.height = height;
    }

    pub fn clear(&mut self) {
        for line in &mut self.lines {
            for cell in &mut line.cells {
                *cell = default_cell();
            }
        }
    }

    pub fn get_cell(&self, x: usize, y: usize) -> Option<&GridCell> {
        self.row(y).and_then(|row| row.get(x))
    }

    pub fn get_cell_mut(&mut self, x: usize, y: usize) -> Option<&mut GridCell> {
        self.lines.get_mut(y).and_then(|line| line.cells.get_mut(x))
    }

    pub fn row(&self, y: usize) -> Option<&[GridCell]> {
        self.lines.get(y).map(|line| line.cells.as_slice())
    }

    /// Scroll the region by `rows`/`cols` as `grid_scroll` describes: positive rows move
    /// content up. Returns true for a pure full-grid vertical scroll, which rotates in O(1)
    /// per line and leaves the scrolled-out lines to be overwritten by later `grid_line`s.
    pub fn scroll_region(&mut self, top: usize, bottom: usize, left: usize, right: usize, rows: isize, cols: isize) -> bool {
        if top == 0 && bottom == self.height && left == 0 && right == self.width && cols == 0 && self.height > 0 {
            let n = rows.unsigned_abs() % self.height;
            if rows > 0 {
                self.lines.rotate_left(n);
            } else {
                self.lines.rotate_right(n);
            }
            return true;
        }

        let rows_range: Box<dyn Iterator<Item = usize>> = if rows > 0 {
            Box::new(((top as isize + rows).max(0) as usize)..bottom)
        } else {
            Box::new((top..((bottom as isize + rows).max(0) as usize)).rev())
        };
        for y in rows_range {
            let dest_y = y as isize - rows;
            if dest_y < 0 || dest_y >= self.height as isize {
                continue;
            }
            let cols_range: Box<dyn Iterator<Item = usize>> = if cols > 0 {
                Box::new(((left as isize + cols).max(0) as usize)..right)
            } else {
                Box::new((left..((right as isize + cols).max(0) as usize)).rev())
            };
            for x in cols_range {
                let dest_x = x as isize - cols;
                if dest_x < 0 {
                    continue;
                }
                if let Some(cell) = self.get_cell(x, y).cloned() {
                    if let Some(dest) = self.get_cell_mut(dest_x as usize, dest_y as usize) {
                        *dest = cell;
                    }
                }
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grid_from(lines: &[&str]) -> CharacterGrid {
        let mut g = CharacterGrid::new((lines[0].len(), lines.len()));
        for (y, l) in lines.iter().enumerate() {
            for (x, c) in l.chars().enumerate() {
                *g.get_cell_mut(x, y).unwrap() = (c.to_string(), None);
            }
        }
        g
    }

    fn text_at(g: &CharacterGrid, x: usize, y: usize) -> &str {
        &g.get_cell(x, y).unwrap().0
    }

    #[test]
    fn full_scroll_down_rotates() {
        let mut g = grid_from(&["abcd", "efgh", "ijkl", "mnop"]);
        assert!(g.scroll_region(0, 4, 0, 4, 2, 0));
        assert_eq!(text_at(&g, 0, 0), "i");
        assert_eq!(text_at(&g, 0, 1), "m");
    }

    #[test]
    fn full_scroll_up_rotates() {
        let mut g = grid_from(&["abcd", "efgh", "ijkl", "mnop"]);
        assert!(g.scroll_region(0, 4, 0, 4, -2, 0));
        assert_eq!(text_at(&g, 0, 2), "a");
        assert_eq!(text_at(&g, 3, 3), "h");
    }

    #[test]
    fn partial_scrolls_copy_cells() {
        let mut g = grid_from(&["abcd", "efgh", "ijkl", "mnop"]);
        assert!(!g.scroll_region(1, 3, 0, 4, 1, 0));
        assert_eq!(text_at(&g, 0, 0), "a");
        assert_eq!(text_at(&g, 0, 1), "i");
        assert_eq!(text_at(&g, 0, 3), "m");

        let mut g = grid_from(&["abcd", "efgh", "ijkl", "mnop"]);
        g.scroll_region(0, 4, 0, 4, 0, 1);
        assert_eq!(text_at(&g, 0, 0), "b");
        let mut g = grid_from(&["abcd", "efgh", "ijkl", "mnop"]);
        g.scroll_region(1, 3, 1, 3, 1, 1);
        assert_eq!(text_at(&g, 1, 1), "k");
        assert_eq!(text_at(&g, 0, 1), "e");
    }

    #[test]
    fn resize_keeps_content() {
        let mut g = grid_from(&["ab", "cd"]);
        g.resize((3, 3));
        assert_eq!(text_at(&g, 1, 1), "d");
        assert_eq!(text_at(&g, 2, 2), " ");
    }
}
