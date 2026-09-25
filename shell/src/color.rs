//! A plain RGBA colour. Neovide used skia's Color4f for this; the shell has no skia.

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Rgba {
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    pub const WHITE: Rgba = Rgba::new(1.0, 1.0, 1.0, 1.0);
    pub const BLACK: Rgba = Rgba::new(0.0, 0.0, 0.0, 1.0);
    pub const GREY: Rgba = Rgba::new(0.5, 0.5, 0.5, 1.0);

    /// Neovim packs colours as 0xRRGGBB in a u64.
    pub fn from_packed(packed: u64) -> Self {
        let p = packed as u32;
        Self {
            r: ((p >> 16) & 0xff) as f32 / 255.0,
            g: ((p >> 8) & 0xff) as f32 / 255.0,
            b: (p & 0xff) as f32 / 255.0,
            a: 1.0,
        }
    }

    pub const fn from_rgb8(r: u8, g: u8, b: u8) -> Self {
        Self { r: r as f32 / 255.0, g: g as f32 / 255.0, b: b as f32 / 255.0, a: 1.0 }
    }

    /// Parse "#rrggbb".
    pub fn from_hex(hex: &str) -> Option<Self> {
        let h = hex.strip_prefix('#')?;
        if h.len() != 6 {
            return None;
        }
        let v = u32::from_str_radix(h, 16).ok()?;
        Some(Self::from_packed(v as u64))
    }

    pub fn with_alpha(self, a: f32) -> Self {
        Self { a, ..self }
    }

    pub fn to_array(self) -> [f32; 4] {
        [self.r, self.g, self.b, self.a]
    }

    /// Relative luminance test used to decide light/dark window theme.
    pub fn is_light(&self) -> bool {
        0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b > 0.5
    }
}
