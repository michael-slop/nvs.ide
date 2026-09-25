//! Cursor shape, colours and blink parameters, from `mode_info_set` / `mode_change`.
//! Ported from Neovide's src/editor/cursor.rs (MIT, LICENSE-NEOVIDE).

use std::{collections::HashMap, sync::Arc};

use crate::color::Rgba;

use super::style::{Colors, Style};

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum CursorShape {
    Block,
    Horizontal,
    Vertical,
}

impl CursorShape {
    pub fn from_type_name(name: &str) -> Option<CursorShape> {
        match name {
            "block" => Some(CursorShape::Block),
            "horizontal" => Some(CursorShape::Horizontal),
            "vertical" => Some(CursorShape::Vertical),
            _ => None,
        }
    }
}

#[derive(Default, Debug, Clone, PartialEq)]
pub struct CursorMode {
    pub shape: Option<CursorShape>,
    pub style_id: Option<u64>,
    pub cell_percentage: Option<f32>,
    pub blinkwait: Option<u64>,
    pub blinkon: Option<u64>,
    pub blinkoff: Option<u64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cursor {
    /// (column, row) inside `parent_grid`.
    pub grid_position: (u64, u64),
    pub parent_grid: u64,
    pub shape: CursorShape,
    pub cell_percentage: Option<f32>,
    pub blinkwait: Option<u64>,
    pub blinkon: Option<u64>,
    pub blinkoff: Option<u64>,
    pub style: Option<Arc<Style>>,
    pub enabled: bool,
    pub double_width: bool,
    /// The text and style of the cell under the cursor, so a block cursor can redraw it inverted.
    pub grid_cell: (String, Option<Arc<Style>>),
}

impl Default for Cursor {
    fn default() -> Self {
        Self {
            grid_position: (0, 0),
            parent_grid: 0,
            shape: CursorShape::Block,
            cell_percentage: None,
            blinkwait: None,
            blinkon: None,
            blinkoff: None,
            style: None,
            enabled: true,
            double_width: false,
            grid_cell: (" ".to_string(), None),
        }
    }
}

impl Cursor {
    fn cell_colors(&self, default: &Colors) -> (Rgba, Rgba) {
        self.grid_cell
            .1
            .as_ref()
            .map(|style| (style.foreground(default), style.background(default)))
            .unwrap_or_else(|| (default.foreground.unwrap_or(Rgba::WHITE), default.background.unwrap_or(Rgba::BLACK)))
    }

    /// Cursor colours: (foreground for the glyph under it, background of the cursor block).
    /// With no cursor highlight, the cell's colours are swapped, as Neovim does.
    pub fn colors(&self, default: &Colors) -> (Rgba, Rgba) {
        let (cell_fg, cell_bg) = self.cell_colors(default);
        match self.style.as_deref() {
            Some(style) => {
                let fg = style.colors.foreground.unwrap_or(cell_bg);
                let bg = style.colors.background.unwrap_or(cell_fg);
                if style.reverse {
                    (bg, fg)
                } else {
                    (fg, bg)
                }
            }
            None => (cell_bg, cell_fg),
        }
    }

    pub fn alpha(&self) -> f32 {
        self.style.as_ref().map(|s| (100 - s.blend) as f32 / 100.0).unwrap_or(1.0)
    }

    pub fn change_mode(&mut self, cursor_mode: &CursorMode, styles: &HashMap<u64, Arc<Style>>) {
        if let Some(shape) = cursor_mode.shape {
            self.shape = shape;
        }
        if let Some(style_id) = cursor_mode.style_id {
            self.style = styles.get(&style_id).cloned();
        }
        self.cell_percentage = cursor_mode.cell_percentage;
        self.blinkwait = cursor_mode.blinkwait;
        self.blinkon = cursor_mode.blinkon;
        self.blinkoff = cursor_mode.blinkoff;
    }

    /// No blinking when either on or off phase is missing or zero (blinkwait may be zero).
    pub fn is_static(&self) -> bool {
        matches!(self.blinkoff, None | Some(0)) || matches!(self.blinkon, None | Some(0))
    }
}
