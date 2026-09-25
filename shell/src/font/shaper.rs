//! Shape words into positioned glyphs, one font per cluster, each cluster pinned to its cell.
//! Follows Neovide's caching_shaper.rs (MIT, LICENSE-NEOVIDE) with skia's TextBlob replaced by
//! plain glyph positions.

use std::{num::NonZeroUsize, sync::Arc};

use lru::LruCache;
use swash::{
    shape::ShapeContext,
    text::{
        cluster::{CharCluster, Parser, Status, Token},
        Script,
    },
};

use super::FontStack;
use crate::editor::Word;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GlyphPos {
    pub font: usize,
    pub glyph: u16,
    /// Pixel offset from the word's first cell origin, at the baseline.
    pub x: f32,
    pub y: f32,
}

#[derive(Clone, Debug, Default)]
pub struct ShapedWord {
    pub glyphs: Vec<GlyphPos>,
}

#[derive(Clone, Hash, PartialEq, Eq)]
struct ShapeKey {
    text: String,
    size_px: u32,
    cell_width: u32,
}

pub struct Shaper {
    context: ShapeContext,
    cache: LruCache<ShapeKey, Arc<ShapedWord>>,
}

impl Default for Shaper {
    fn default() -> Self {
        Self::new()
    }
}

impl Shaper {
    pub fn new() -> Self {
        Shaper { context: ShapeContext::new(), cache: LruCache::new(NonZeroUsize::new(20_000).unwrap()) }
    }

    pub fn clear(&mut self) {
        self.cache.clear();
    }

    pub fn shape(&mut self, fonts: &mut FontStack, word: &Word) -> Arc<ShapedWord> {
        let metrics = fonts.metrics();
        let key = ShapeKey { text: word.text.clone(), size_px: metrics.size_px as u32, cell_width: metrics.width as u32 };
        if let Some(cached) = self.cache.get(&key) {
            return cached.clone();
        }
        let shaped = Arc::new(self.shape_uncached(fonts, word));
        self.cache.put(key, shaped.clone());
        shaped
    }

    fn shape_uncached(&mut self, fonts: &mut FontStack, word: &Word) -> ShapedWord {
        let metrics = fonts.metrics();
        let cell_width = metrics.width;
        let size = metrics.size_px;

        // Tokens carry the cell index as user data so each cluster lands on its own cell.
        let tokens: Vec<Token> = word
            .clusters()
            .flat_map(|(cell, cluster)| {
                cluster.char_indices().map(move |(offset, ch)| Token {
                    ch,
                    offset: offset as u32,
                    len: ch.len_utf8() as u8,
                    info: ch.into(),
                    data: cell as u32,
                })
            })
            .collect();

        // Pick a font per cluster and group consecutive clusters that share one.
        let mut parser = Parser::new(Script::Latin, tokens.into_iter());
        let mut cluster = CharCluster::new();
        let mut groups: Vec<(usize, Vec<CharCluster>)> = Vec::new();
        while parser.next(&mut cluster) {
            let first = cluster.chars().first().map(|c| c.ch).unwrap_or(' ');
            let font_id = fonts.font_for_char(first);
            let charmap = fonts.font(font_id).as_ref().charmap();
            let mut owned = cluster.to_owned();
            match owned.map(|ch| charmap.map(ch)) {
                Status::Discard | Status::Keep | Status::Complete => {}
            }
            match groups.last_mut() {
                Some((id, list)) if *id == font_id => list.push(owned),
                _ => groups.push((font_id, vec![owned])),
            }
        }

        let mut glyphs = Vec::new();
        for (font_id, clusters) in groups {
            let font = fonts.font(font_id);
            let mut shaper = self.context.builder(font.as_ref()).script(Script::Latin).size(size).build();
            for c in &clusters {
                shaper.add_cluster(c);
            }
            shaper.shape_with(|glyph_cluster| {
                let mut x = cell_width * glyph_cluster.data as f32;
                for glyph in glyph_cluster.glyphs {
                    glyphs.push(GlyphPos { font: font_id, glyph: glyph.id, x: x + glyph.x, y: -glyph.y });
                    x += glyph.advance;
                }
            });
        }
        ShapedWord { glyphs }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::font::FontOptions;

    #[test]
    fn each_cluster_lands_on_its_cell() {
        let Ok(mut fonts) = FontStack::new(FontOptions::default(), 1.0) else { return };
        let mut shaper = Shaper::new();
        let word = Word { text: "ab✓c".into(), cell: 0, cluster_sizes: vec![1, 1, 3, 1] };
        let shaped = shaper.shape(&mut fonts, &word);
        let w = fonts.metrics().width;
        assert_eq!(shaped.glyphs.len(), 4, "{:?}", shaped.glyphs);
        for (i, g) in shaped.glyphs.iter().enumerate() {
            assert!((g.x - i as f32 * w).abs() < 0.01, "glyph {i} at x={} expected {}", g.x, i as f32 * w);
        }
        assert!(Arc::ptr_eq(&shaped, &shaper.shape(&mut fonts, &word)), "second call is cached");
    }
}
