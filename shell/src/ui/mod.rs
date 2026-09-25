//! The workbench's widget layer: immediate mode, pixel positioned, drawn with the same glyph
//! renderer as the editor. The house style is monospace text, flat colours and 2-px Win98
//! bevels, so the whole toolkit is rectangles and text.

pub mod widgets;

use winit::keyboard::{Key, ModifiersState, NamedKey};

use crate::color::Rgba;
use crate::renderer::{AtlasFull, Painter};

/// The necronomicon palette (runtime/colors/necronomicon.lua, docs/preview/src.html).
pub mod theme {
    use crate::color::Rgba;
    pub const VOID: Rgba = Rgba::from_rgb8(0x05, 0x07, 0x0a);
    pub const CRYPT: Rgba = Rgba::from_rgb8(0x0a, 0x0e, 0x14);
    pub const CRYPT_HI: Rgba = Rgba::from_rgb8(0x11, 0x18, 0x23);
    pub const STONE: Rgba = Rgba::from_rgb8(0x1a, 0x24, 0x30);
    pub const STONE_HI: Rgba = Rgba::from_rgb8(0x26, 0x33, 0x3f);
    pub const BONE: Rgba = Rgba::from_rgb8(0xd8, 0xd4, 0xc4);
    pub const BONE_DIM: Rgba = Rgba::from_rgb8(0x8b, 0x87, 0x78);
    pub const ASH: Rgba = Rgba::from_rgb8(0x5c, 0x64, 0x70);
    pub const SPECTRAL: Rgba = Rgba::from_rgb8(0x62, 0xe6, 0x70);
    pub const SPECTRAL_HI: Rgba = Rgba::from_rgb8(0xc8, 0xff, 0xd0);
    pub const CORPSE: Rgba = Rgba::from_rgb8(0x4f, 0xb8, 0xd6);
    pub const NECROTIC: Rgba = Rgba::from_rgb8(0x9d, 0x6b, 0xd8);
    pub const VISCERA: Rgba = Rgba::from_rgb8(0xb8, 0x45, 0x3a);
    pub const GOLD: Rgba = Rgba::from_rgb8(0xd4, 0xa8, 0x43);
}

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Rect { x, y, w, h }
    }

    pub fn contains(&self, px: f32, py: f32) -> bool {
        px >= self.x && py >= self.y && px < self.x + self.w && py < self.y + self.h
    }

    pub fn inset(&self, d: f32) -> Rect {
        Rect::new(self.x + d, self.y + d, (self.w - 2.0 * d).max(0.0), (self.h - 2.0 * d).max(0.0))
    }

    pub fn right(&self) -> f32 {
        self.x + self.w
    }

    pub fn bottom(&self) -> f32 {
        self.y + self.h
    }
}

/// A key press for the chrome, already reduced to what widgets care about.
#[derive(Clone, Debug)]
pub struct KeyPress {
    pub key: Key,
    pub modifiers: ModifiersState,
    pub text: Option<String>,
}

impl KeyPress {
    pub fn named(&self, name: NamedKey) -> bool {
        self.key == Key::Named(name)
    }

    pub fn is_char(&self, c: &str) -> bool {
        !self.modifiers.control_key() && !self.modifiers.alt_key() && matches!(&self.key, Key::Character(s) if s.as_str() == c)
    }

    pub fn ctrl(&self, c: &str) -> bool {
        self.modifiers.control_key() && matches!(&self.key, Key::Character(s) if s.eq_ignore_ascii_case(c))
    }
}

#[derive(Clone, Debug)]
pub enum UiEvent {
    PointerMove { x: f32, y: f32 },
    PointerDown { x: f32, y: f32, right: bool },
    PointerUp { x: f32, y: f32 },
    Scroll { x: f32, y: f32, lines: f32 },
    Key(KeyPress),
}

/// Input for one UI pass: the events since the last pass plus the pointer state.
#[derive(Default)]
pub struct UiInput {
    pub events: Vec<UiEvent>,
    pub mouse: (f32, f32),
    pub mouse_down: bool,
}

impl UiInput {
    /// Did a press land inside `rect` this pass?
    pub fn clicked(&self, rect: &Rect) -> bool {
        self.events.iter().any(|e| matches!(e, UiEvent::PointerDown { x, y, right: false } if rect.contains(*x, *y)))
    }

    pub fn right_clicked(&self, rect: &Rect) -> bool {
        self.events.iter().any(|e| matches!(e, UiEvent::PointerDown { x, y, right: true } if rect.contains(*x, *y)))
    }

    pub fn hovered(&self, rect: &Rect) -> bool {
        rect.contains(self.mouse.0, self.mouse.1)
    }

    /// Wheel lines scrolled over `rect` this pass (positive = down).
    pub fn scrolled(&self, rect: &Rect) -> f32 {
        self.events
            .iter()
            .filter_map(|e| match e {
                UiEvent::Scroll { x, y, lines } if rect.contains(*x, *y) => Some(-*lines),
                _ => None,
            })
            .sum()
    }

    pub fn keys(&self) -> impl Iterator<Item = &KeyPress> {
        self.events.iter().filter_map(|e| match e {
            UiEvent::Key(k) => Some(k),
            _ => None,
        })
    }
}

/// Draw a 2-px Win98 bevel inside `rect`. Raised: light top-left, dark bottom-right.
pub fn bevel(p: &mut Painter, rect: Rect, raised: bool) {
    let (tl, br) = if raised { (theme::STONE_HI, theme::VOID) } else { (theme::VOID, theme::STONE_HI) };
    let w = 2.0;
    p.rect(rect.x, rect.y, rect.w, w, tl);
    p.rect(rect.x, rect.y, w, rect.h, tl);
    p.rect(rect.x, rect.bottom() - w, rect.w, w, br);
    p.rect(rect.right() - w, rect.y, w, rect.h, br);
}

/// Truncate `text` to `max_cells` cells, with an ellipsis-free hard cut (monospace).
pub fn fit(text: &str, max_cells: usize) -> String {
    if text.chars().count() <= max_cells {
        return text.to_string();
    }
    if max_cells <= 1 {
        return text.chars().take(max_cells).collect();
    }
    let mut s: String = text.chars().take(max_cells - 1).collect();
    s.push('…');
    s
}

/// Draw text clipped to `max_cells` cells at (x, y) where y is the cell top.
pub fn label(p: &mut Painter, text: &str, x: f32, y: f32, max_cells: usize, color: Rgba) -> Result<(), AtlasFull> {
    if max_cells == 0 {
        return Ok(());
    }
    let shown = fit(text, max_cells);
    p.text(&shown, x, y, color)
}

/// Text vertically centred in a rect of any height.
pub fn label_centered_y(p: &mut Painter, text: &str, x: f32, rect: &Rect, max_cells: usize, color: Rgba) -> Result<(), AtlasFull> {
    let ch = p.fonts.metrics().height;
    let y = (rect.y + (rect.h - ch) / 2.0).round();
    label(p, text, x, y, max_cells, color)
}

/// Draw a pixel icon (see renderer::icons) with its top-left at (x, y), each source pixel
/// `scale` px wide.
pub fn icon(p: &mut Painter, name: &str, x: f32, y: f32, scale: u32, color: Rgba) -> Result<(), AtlasFull> {
    p.icon(name, x, y, scale, color)
}
