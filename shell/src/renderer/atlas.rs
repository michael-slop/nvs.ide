//! Glyph atlas: rasterise glyphs with swash into two GPU textures (an R8 coverage mask and an
//! RGBA colour atlas for emoji/bitmap glyphs) and hand out UV rectangles.

use std::collections::HashMap;

use etagere::{size2, AtlasAllocator};
use swash::scale::{image::Content, Render, ScaleContext, Source, StrikeWith};
use swash::zeno::Format;

use crate::font::FontStack;

/// Fake font id for procedurally drawn tiles (the undercurl wave, pixel icons).
pub const TILE_FONT: usize = usize::MAX;
pub const UNDERCURL_TILE: u16 = 1;
/// Icon tiles: glyph = ICON_TILE_BASE + icon index, size_q = pixel scale.
pub const ICON_TILE_BASE: u16 = 100;

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
pub struct GlyphKey {
    pub font: usize,
    pub glyph: u16,
    /// Pixel size times 4, so fractional sizes still get distinct entries.
    pub size_q: u32,
    pub bold: bool,
    pub italic: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct AtlasGlyph {
    /// u0, v0, u1, v1
    pub uv: [f32; 4],
    pub width: f32,
    pub height: f32,
    /// Bitmap offset from the glyph origin: `left` to the right, `top` upwards from the baseline.
    pub left: f32,
    pub top: f32,
    pub color: bool,
}

#[derive(Debug)]
pub struct AtlasFull;

struct Page {
    texture: wgpu::Texture,
    pub view: wgpu::TextureView,
    allocator: AtlasAllocator,
    size: u32,
    format: wgpu::TextureFormat,
    bytes_per_pixel: u32,
}

impl Page {
    fn new(device: &wgpu::Device, size: u32, format: wgpu::TextureFormat, bytes_per_pixel: u32, label: &str) -> Self {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d { width: size, height: size, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        Page { texture, view, allocator: AtlasAllocator::new(size2(size as i32, size as i32)), size, format, bytes_per_pixel }
    }

    /// Upload a bitmap with a one-pixel transparent border; returns the inner rectangle.
    fn upload(&mut self, queue: &wgpu::Queue, width: u32, height: u32, data: &[u8]) -> Option<(u32, u32)> {
        let alloc = self.allocator.allocate(size2(width as i32 + 2, height as i32 + 2))?;
        let x = alloc.rectangle.min.x as u32;
        let y = alloc.rectangle.min.y as u32;
        // Border: write a zeroed block covering the padded rectangle first.
        let padded_w = width + 2;
        let padded_h = height + 2;
        let zero = vec![0u8; (padded_w * padded_h * self.bytes_per_pixel) as usize];
        queue.write_texture(
            wgpu::TexelCopyTextureInfo { texture: &self.texture, mip_level: 0, origin: wgpu::Origin3d { x, y, z: 0 }, aspect: wgpu::TextureAspect::All },
            &zero,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(padded_w * self.bytes_per_pixel), rows_per_image: Some(padded_h) },
            wgpu::Extent3d { width: padded_w, height: padded_h, depth_or_array_layers: 1 },
        );
        if width > 0 && height > 0 {
            queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &self.texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d { x: x + 1, y: y + 1, z: 0 },
                    aspect: wgpu::TextureAspect::All,
                },
                data,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(width * self.bytes_per_pixel), rows_per_image: Some(height) },
                wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            );
        }
        Some((x + 1, y + 1))
    }
}

pub struct Atlas {
    mask: Page,
    color: Page,
    glyphs: HashMap<GlyphKey, Option<AtlasGlyph>>,
    scale_context: ScaleContext,
    /// Bumped whenever a texture is recreated, so the bind group gets rebuilt.
    pub generation: u64,
}

impl Atlas {
    pub fn new(device: &wgpu::Device) -> Self {
        Atlas {
            mask: Page::new(device, 1024, wgpu::TextureFormat::R8Unorm, 1, "glyph mask atlas"),
            color: Page::new(device, 512, wgpu::TextureFormat::Rgba8Unorm, 4, "glyph color atlas"),
            glyphs: HashMap::new(),
            scale_context: ScaleContext::new(),
            generation: 0,
        }
    }

    pub fn mask_view(&self) -> &wgpu::TextureView {
        &self.mask.view
    }

    pub fn color_view(&self) -> &wgpu::TextureView {
        &self.color.view
    }

    /// Forget every glyph (font or size changed).
    pub fn clear(&mut self, device: &wgpu::Device) {
        let mask_size = self.mask.size;
        let color_size = self.color.size;
        self.mask = Page::new(device, mask_size, wgpu::TextureFormat::R8Unorm, 1, "glyph mask atlas");
        self.color = Page::new(device, color_size, wgpu::TextureFormat::Rgba8Unorm, 4, "glyph color atlas");
        self.glyphs.clear();
        self.generation += 1;
    }

    fn grow(&mut self, device: &wgpu::Device, color: bool) -> bool {
        let page = if color { &mut self.color } else { &mut self.mask };
        if page.size >= 4096 {
            // Out of room even at the maximum: start over with what is still needed.
            self.clear(device);
            return true;
        }
        let new_size = page.size * 2;
        let (format, bpp, label) = (page.format, page.bytes_per_pixel, if color { "glyph color atlas" } else { "glyph mask atlas" });
        *page = Page::new(device, new_size, format, bpp, label);
        self.glyphs.retain(|_, v| v.map(|g| g.color != color).unwrap_or(true));
        self.generation += 1;
        log::info!("{label} grown to {new_size}");
        true
    }

    /// Look up or rasterise a glyph. `Err(AtlasFull)` means a texture was recreated and the
    /// caller must rebuild its quads from scratch (earlier UVs are stale).
    pub fn get(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, fonts: &FontStack, key: GlyphKey) -> Result<Option<AtlasGlyph>, AtlasFull> {
        if let Some(entry) = self.glyphs.get(&key) {
            return Ok(*entry);
        }
        let Some((width, height, left, top, color, data)) = self.rasterize(fonts, key) else {
            self.glyphs.insert(key, None);
            return Ok(None);
        };
        let page = if color { &mut self.color } else { &mut self.mask };
        let Some((x, y)) = page.upload(queue, width, height, &data) else {
            self.grow(device, color);
            return Err(AtlasFull);
        };
        let size = page.size as f32;
        let glyph = AtlasGlyph {
            uv: [x as f32 / size, y as f32 / size, (x + width) as f32 / size, (y + height) as f32 / size],
            width: width as f32,
            height: height as f32,
            left,
            top,
            color,
        };
        self.glyphs.insert(key, Some(glyph));
        Ok(Some(glyph))
    }

    /// Returns (width, height, left, top, is_color, pixels).
    fn rasterize(&mut self, fonts: &FontStack, key: GlyphKey) -> Option<(u32, u32, f32, f32, bool, Vec<u8>)> {
        if key.font == TILE_FONT {
            return Some(rasterize_tile(key));
        }
        let size = key.size_q as f32 / 4.0;
        let font = fonts.font(key.font);
        let mut scaler = self.scale_context.builder(font.as_ref()).size(size).hint(true).build();
        let mut render = Render::new(&[Source::ColorOutline(0), Source::ColorBitmap(StrikeWith::BestFit), Source::Outline]);
        render.format(Format::Alpha);
        if key.bold {
            render.embolden((size / 24.0).max(0.5));
        }
        if key.italic {
            render.transform(Some(swash::zeno::Transform::skew(swash::zeno::Angle::from_degrees(14.0), swash::zeno::Angle::ZERO)));
        }
        let image = render.render(&mut scaler, key.glyph)?;
        let p = image.placement;
        if p.width == 0 || p.height == 0 {
            return None;
        }
        match image.content {
            Content::Mask => Some((p.width, p.height, p.left as f32, p.top as f32, false, image.data)),
            Content::Color | Content::SubpixelMask => Some((p.width, p.height, p.left as f32, p.top as f32, true, image.data)),
        }
    }
}

/// Procedural tiles. The undercurl is one cell wide and three strokes tall: a sine wave that
/// tiles seamlessly across cells. `key.glyph` selects the tile, `key.size_q` carries the cell
/// width times 4 and `bold` is unused.
fn rasterize_tile(key: GlyphKey) -> (u32, u32, f32, f32, bool, Vec<u8>) {
    if key.glyph >= ICON_TILE_BASE {
        return match super::icons::rasterize(key.glyph - ICON_TILE_BASE, key.size_q.max(1)) {
            Some((w, h, data)) => (w, h, 0.0, 0.0, false, data),
            None => (1, 1, 0.0, 0.0, false, vec![0]),
        };
    }
    match key.glyph {
        UNDERCURL_TILE => {
            let width = (key.size_q / 4).max(2);
            let stroke = ((width as f32) / 8.0).round().max(1.0);
            let height = (stroke * 3.0).round() as u32 + 1;
            let mut data = vec![0u8; (width * height) as usize];
            let amplitude = (height as f32 - stroke) / 2.0;
            let centre = height as f32 / 2.0;
            for x in 0..width {
                let phase = (x as f32 + 0.5) / width as f32 * std::f32::consts::TAU;
                let wave_y = centre - amplitude * phase.sin();
                for y in 0..height {
                    let d = ((y as f32 + 0.5) - wave_y).abs();
                    let cover = (stroke / 2.0 + 0.5 - d).clamp(0.0, 1.0);
                    data[(y * width + x) as usize] = (cover * 255.0) as u8;
                }
            }
            (width, height, 0.0, 0.0, false, data)
        }
        _ => (1, 1, 0.0, 0.0, false, vec![255]),
    }
}
