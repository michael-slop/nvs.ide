//! Highlight styles as Neovim defines them in `hl_attr_define`.
//! Ported from Neovide's src/editor/style.rs (MIT, LICENSE-NEOVIDE).

use crate::color::Rgba;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Colors {
    pub foreground: Option<Rgba>,
    pub background: Option<Rgba>,
    /// Colour for underlines and undercurls.
    pub special: Option<Rgba>,
}

impl Colors {
    pub fn new(foreground: Option<Rgba>, background: Option<Rgba>, special: Option<Rgba>) -> Self {
        Self { foreground, background, special }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash)]
pub enum UnderlineStyle {
    Underline,
    UnderDouble,
    UnderDash,
    UnderDot,
    UnderCurl,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Style {
    pub colors: Colors,
    pub reverse: bool,
    pub italic: bool,
    pub bold: bool,
    pub strikethrough: bool,
    /// Blend level 0..=100 (from 'winblend' / 'pumblend').
    pub blend: u8,
    pub underline: Option<UnderlineStyle>,
}

impl Style {
    pub fn new(colors: Colors) -> Self {
        Self { colors, ..Default::default() }
    }

    pub fn foreground(&self, default: &Colors) -> Rgba {
        if self.reverse {
            self.colors.background.unwrap_or_else(|| default.background.unwrap_or(Rgba::BLACK))
        } else {
            self.colors.foreground.unwrap_or_else(|| default.foreground.unwrap_or(Rgba::WHITE))
        }
    }

    pub fn background(&self, default: &Colors) -> Rgba {
        if self.reverse {
            self.colors.foreground.unwrap_or_else(|| default.foreground.unwrap_or(Rgba::WHITE))
        } else {
            self.colors.background.unwrap_or_else(|| default.background.unwrap_or(Rgba::BLACK))
        }
    }

    pub fn special(&self, default: &Colors) -> Rgba {
        self.colors.special.unwrap_or_else(|| self.foreground(default))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reverse_swaps_colours_and_falls_back_to_defaults() {
        let default = Colors::new(Some(Rgba::new(0.1, 0.2, 0.3, 1.0)), Some(Rgba::new(0.4, 0.5, 0.6, 1.0)), None);
        let mut style = Style::new(Colors::new(Some(Rgba::WHITE), None, None));
        assert_eq!(style.foreground(&default), Rgba::WHITE);
        assert_eq!(style.background(&default), default.background.unwrap());
        style.reverse = true;
        assert_eq!(style.foreground(&default), default.background.unwrap());
        assert_eq!(style.background(&default), Rgba::WHITE);
        assert_eq!(style.special(&default), default.background.unwrap());
    }
}
