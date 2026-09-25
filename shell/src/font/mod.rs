//! Fonts: the house font, system fallbacks for glyphs it lacks, and the cell metrics.
//!
//! swash has no font fallback of its own (Neovide got it from skia's font manager), so this
//! module enumerates system fonts with fontdb and picks a font per character: the primary
//! font if it has the glyph, then a fallback list, then any installed face that has it.

pub mod shaper;

use std::{collections::HashMap, sync::Arc};

use swash::{CacheKey, FontRef};

/// Parsed 'guifont': family list and size. `:h<n>` is in points, converted at 96 dpi
/// (13pt = 17.33px) so it means the same as it does in Neovide.
#[derive(Clone, Debug, PartialEq)]
pub struct FontOptions {
    pub families: Vec<String>,
    /// Size in points.
    pub size_pt: f32,
    /// Extra cell width in pixels (`:w<n>`).
    pub width_extra: f32,
}

impl Default for FontOptions {
    fn default() -> Self {
        Self {
            families: vec!["BigBlueTerm437 Nerd Font Mono".into(), "Cascadia Mono".into(), "Consolas".into(), "Courier New".into()],
            size_pt: 9.0,
            width_extra: 0.0,
        }
    }
}

impl FontOptions {
    /// Parse "Family One:h9,Family Two:h9:w1". Escaped spaces (`\ `) are unescaped.
    pub fn parse(guifont: &str) -> Option<Self> {
        let guifont = guifont.trim();
        if guifont.is_empty() || guifont == "*" {
            return None;
        }
        let mut families = Vec::new();
        let mut size_pt = FontOptions::default().size_pt;
        let mut width_extra = 0.0;
        for entry in split_unescaped(guifont, ',') {
            let mut parts = split_unescaped(&entry, ':').into_iter();
            let family = parts.next().unwrap_or_default().replace("\\ ", " ").trim().to_string();
            if !family.is_empty() {
                families.push(family);
            }
            for opt in parts {
                if let Some(h) = opt.strip_prefix('h') {
                    if let Ok(v) = h.parse::<f32>() {
                        size_pt = v;
                    }
                } else if let Some(w) = opt.strip_prefix('w') {
                    if let Ok(v) = w.parse::<f32>() {
                        width_extra = v;
                    }
                }
            }
        }
        if families.is_empty() {
            return None;
        }
        Some(FontOptions { families, size_pt, width_extra })
    }

    pub fn size_px(&self, scale: f32) -> f32 {
        // Points to pixels at 96 dpi, then the window scale; whole pixels keep pixel fonts crisp.
        (self.size_pt * 96.0 / 72.0 * scale).round().max(4.0)
    }
}

fn split_unescaped(s: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(n) = chars.next() {
                cur.push('\\');
                cur.push(n);
            }
        } else if c == sep {
            out.push(std::mem::take(&mut cur));
        } else {
            cur.push(c);
        }
    }
    out.push(cur);
    out
}

pub struct LoadedFont {
    pub data: Arc<Vec<u8>>,
    pub index: u32,
    pub offset: u32,
    pub key: CacheKey,
    pub family: String,
}

impl LoadedFont {
    fn from_data(data: Arc<Vec<u8>>, index: u32, family: String) -> Option<Self> {
        let font = FontRef::from_index(&data, index as usize)?;
        let (offset, key) = (font.offset, font.key);
        Some(Self { data, index, offset, key, family })
    }

    pub fn as_ref(&self) -> FontRef<'_> {
        FontRef { data: &self.data, offset: self.offset, key: self.key }
    }

    pub fn has_glyph(&self, c: char) -> bool {
        self.as_ref().charmap().map(c) != 0
    }
}

/// Pixel geometry of one cell for the current font and size.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CellMetrics {
    pub width: f32,
    pub height: f32,
    /// Distance from the cell top to the baseline.
    pub baseline: f32,
    /// Underline position below the baseline (positive = down) and its thickness.
    pub underline_offset: f32,
    pub stroke_size: f32,
    pub size_px: f32,
}

pub struct FontStack {
    db: fontdb::Database,
    fonts: Vec<LoadedFont>,
    /// Index into `fonts` of the primary font.
    primary: usize,
    fallback_families: Vec<String>,
    fallbacks_loaded: bool,
    char_cache: HashMap<char, usize>,
    scanned_all: bool,
    pub options: FontOptions,
    pub scale: f32,
    pub linespace: f32,
    metrics: CellMetrics,
}

const DEFAULT_FALLBACKS: &[&str] = &[
    "Segoe UI Symbol",
    "Segoe UI Emoji",
    "Cascadia Mono",
    "Consolas",
    "Segoe UI",
    "DejaVu Sans Mono",
    "Noto Sans Mono",
    "Noto Sans Symbols2",
];

impl FontStack {
    pub fn new(options: FontOptions, scale: f32) -> anyhow::Result<Self> {
        let mut db = fontdb::Database::new();
        db.load_system_fonts();
        #[cfg(windows)]
        if let Ok(local) = std::env::var("LOCALAPPDATA") {
            db.load_fonts_dir(std::path::Path::new(&local).join("Microsoft").join("Windows").join("Fonts"));
        }
        log::info!("fontdb: {} faces", db.len());
        let mut stack = FontStack {
            db,
            fonts: Vec::new(),
            primary: 0,
            fallback_families: DEFAULT_FALLBACKS.iter().map(|s| s.to_string()).collect(),
            fallbacks_loaded: false,
            char_cache: HashMap::new(),
            scanned_all: false,
            options: options.clone(),
            scale,
            linespace: 0.0,
            metrics: CellMetrics { width: 8.0, height: 12.0, baseline: 10.0, underline_offset: 1.0, stroke_size: 1.0, size_px: 12.0 },
        };
        stack.load_primary(&options)?;
        Ok(stack)
    }

    fn load_family(&mut self, family: &str) -> Option<usize> {
        if let Some(i) = self.fonts.iter().position(|f| f.family.eq_ignore_ascii_case(family)) {
            return Some(i);
        }
        let query = fontdb::Query { families: &[fontdb::Family::Name(family)], ..Default::default() };
        let id = self.db.query(&query)?;
        let info = self.db.face(id)?;
        // fontdb returns the closest face to the query; only accept an exact family match.
        if !info.families.iter().any(|(name, _)| name.eq_ignore_ascii_case(family)) {
            return None;
        }
        let index = info.index;
        let data = self.db.with_face_data(id, |data, _| data.to_vec())?;
        let font = LoadedFont::from_data(Arc::new(data), index, family.to_string())?;
        self.fonts.push(font);
        Some(self.fonts.len() - 1)
    }

    fn load_primary(&mut self, options: &FontOptions) -> anyhow::Result<()> {
        let mut primary = None;
        for family in &options.families {
            if let Some(i) = self.load_family(family) {
                primary = Some(i);
                break;
            }
            log::warn!("font not found: {family}");
        }
        let primary = match primary {
            Some(i) => i,
            None => {
                // Any monospace face at all.
                let query = fontdb::Query { families: &[fontdb::Family::Monospace], ..Default::default() };
                let id = self.db.query(&query).ok_or_else(|| anyhow::anyhow!("no monospace font installed"))?;
                let info = self.db.face(id).unwrap();
                let family = info.families.first().map(|f| f.0.clone()).unwrap_or_default();
                log::warn!("falling back to {family}");
                self.load_family(&family).ok_or_else(|| anyhow::anyhow!("could not load {family}"))?
            }
        };
        self.primary = primary;
        self.options = options.clone();
        self.char_cache.clear();
        self.recompute_metrics();
        log::info!("primary font: {} at {} px, cell {}x{}", self.fonts[primary].family, self.metrics.size_px, self.metrics.width, self.metrics.height);
        Ok(())
    }

    pub fn set_options(&mut self, options: FontOptions) -> anyhow::Result<()> {
        self.load_primary(&options)
    }

    pub fn set_scale(&mut self, scale: f32) {
        self.scale = scale;
        self.recompute_metrics();
    }

    pub fn set_linespace(&mut self, linespace: f32) {
        self.linespace = linespace;
        self.recompute_metrics();
    }

    fn recompute_metrics(&mut self) {
        let size_px = self.options.size_px(self.scale);
        let font = &self.fonts[self.primary];
        let metrics = font.as_ref().metrics(&[]).scale(size_px);
        // Advance of 'M' (Neovide's rule); the font's average width if M is missing.
        let charmap = font.as_ref().charmap();
        let gid = charmap.map('M');
        let advance = if gid != 0 { font.as_ref().glyph_metrics(&[]).scale(size_px).advance_width(gid) } else { metrics.average_width };
        let width = (advance + self.options.width_extra * self.scale).round().max(1.0);
        let bare_height = metrics.ascent + metrics.descent + metrics.leading;
        let height = (bare_height + self.linespace).ceil().max(1.0);
        let baseline = (metrics.ascent + (metrics.leading + self.linespace) / 2.0).round();
        let underline_offset = if metrics.underline_offset != 0.0 { -metrics.underline_offset } else { metrics.stroke_size }.max(1.0).round();
        let stroke_size = metrics.stroke_size.max(1.0).round();
        self.metrics = CellMetrics { width, height, baseline, underline_offset, stroke_size, size_px };
    }

    pub fn metrics(&self) -> CellMetrics {
        self.metrics
    }

    pub fn primary(&self) -> usize {
        self.primary
    }

    pub fn font(&self, id: usize) -> &LoadedFont {
        &self.fonts[id]
    }

    fn load_fallbacks(&mut self) {
        if self.fallbacks_loaded {
            return;
        }
        self.fallbacks_loaded = true;
        let families = self.fallback_families.clone();
        for family in families {
            if self.load_family(&family).is_none() {
                log::debug!("fallback font not installed: {family}");
            }
        }
    }

    /// The font to draw `c` with: primary, then fallbacks, then any face that has it.
    pub fn font_for_char(&mut self, c: char) -> usize {
        if let Some(&id) = self.char_cache.get(&c) {
            return id;
        }
        let primary = self.primary;
        if self.fonts[primary].has_glyph(c) || c.is_whitespace() {
            self.char_cache.insert(c, primary);
            return primary;
        }
        self.load_fallbacks();
        if let Some(i) = self.fonts.iter().position(|f| f.has_glyph(c)) {
            self.char_cache.insert(c, i);
            return i;
        }
        // Last resort: scan every installed face once for this char.
        if !self.scanned_all {
            let candidates: Vec<(fontdb::ID, String)> = self
                .db
                .faces()
                .filter(|f| !f.families.is_empty())
                .map(|f| (f.id, f.families[0].0.clone()))
                .collect();
            for (id, family) in candidates {
                let has = self.db.with_face_data(id, |data, index| {
                    FontRef::from_index(data, index as usize).map(|f| f.charmap().map(c) != 0).unwrap_or(false)
                });
                if has == Some(true) {
                    if let Some(i) = self.load_family(&family) {
                        log::info!("glyph U+{:04X} found in {family}", c as u32);
                        self.char_cache.insert(c, i);
                        return i;
                    }
                }
            }
            log::debug!("no installed font has U+{:04X}", c as u32);
        }
        self.char_cache.insert(c, primary);
        primary
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_guifont_with_escapes_and_sizes() {
        let o = FontOptions::parse("BigBlueTerm437\\ Nerd\\ Font\\ Mono:h9,Consolas:h9:w1").unwrap();
        assert_eq!(o.families, vec!["BigBlueTerm437 Nerd Font Mono", "Consolas"]);
        assert_eq!(o.size_pt, 9.0);
        assert_eq!(o.width_extra, 1.0);
        assert_eq!(o.size_px(1.0), 12.0);
        assert_eq!(o.size_px(2.0), 24.0);
        assert!(FontOptions::parse("").is_none());
        assert!(FontOptions::parse("*").is_none());
    }

    #[test]
    fn house_font_metrics_are_on_grid() {
        // Only meaningful where the font is installed (pHub, the laptop).
        let Ok(mut stack) = FontStack::new(FontOptions::default(), 1.0) else { return };
        if stack.font(stack.primary()).family != "BigBlueTerm437 Nerd Font Mono" {
            return;
        }
        let m = stack.metrics();
        assert_eq!((m.width, m.height), (8.0, 12.0), "{m:?}");
        assert_eq!(m.baseline, 10.0);
        let check = stack.font_for_char('✓');
        assert_ne!(check, stack.primary(), "the house font lacks the check mark; a fallback must supply it");
        assert_eq!(stack.font_for_char('a'), stack.primary());
    }
}
