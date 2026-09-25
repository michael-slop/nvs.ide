//! The wgpu renderer: one instanced-quad pipeline draws Neovim's grids and, later, the
//! workbench chrome, all from the same glyph atlas.

pub mod atlas;
pub mod blink;
pub mod icons;

use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt;
use winit::window::Window;

use crate::color::Rgba;
use crate::editor::{CursorShape, Frame, UnderlineStyle, WindowFrame, Word};
use crate::font::{shaper::Shaper, FontStack};
use crate::input::WindowRegion;

pub use atlas::{Atlas, AtlasFull, GlyphKey, TILE_FONT, UNDERCURL_TILE};

#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct Quad {
    pub pos: [f32; 2],
    pub size: [f32; 2],
    pub uv: [f32; 4],
    pub color: [f32; 4],
    pub kind: u32,
    pub _pad: [u32; 3],
}

pub const KIND_SOLID: u32 = 0;
pub const KIND_MASK: u32 = 1;
pub const KIND_COLOR: u32 = 2;

impl Quad {
    pub fn solid(x: f32, y: f32, w: f32, h: f32, color: Rgba) -> Self {
        Quad { pos: [x, y], size: [w, h], uv: [0.0; 4], color: color.to_array(), kind: KIND_SOLID, _pad: [0; 3] }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Globals {
    screen_size: [f32; 2],
    srgb_surface: f32,
    _pad: f32,
}

pub struct Gpu {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    srgb: bool,
    pipeline: wgpu::RenderPipeline,
    bind_group_layout: wgpu::BindGroupLayout,
    bind_group: wgpu::BindGroup,
    sampler: wgpu::Sampler,
    globals: wgpu::Buffer,
    instances: wgpu::Buffer,
    instance_capacity: usize,
    pub atlas: Atlas,
    atlas_generation: u64,
    pub adapter_name: String,
    pub backend: wgpu::Backend,
    can_capture: bool,
}

/// A frame read back from the GPU: RGBA8, row-major, top-left first.
pub struct Capture {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl Capture {
    pub fn save_png(&self, path: &std::path::Path) -> anyhow::Result<()> {
        image::save_buffer(path, &self.rgba, self.width, self.height, image::ColorType::Rgba8)?;
        Ok(())
    }
}

impl Gpu {
    pub fn new(window: Arc<Window>, backends: wgpu::Backends) -> Result<Gpu> {
        let size = window.inner_size();
        let mut desc = wgpu::InstanceDescriptor::new_without_display_handle_from_env();
        desc.backends = backends;
        let instance = wgpu::Instance::new(desc);
        let surface = instance.create_surface(window.clone()).context("create_surface")?;
        let adapter = futures::executor::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter: false,
            compatible_surface: Some(&surface),
            apply_limit_buckets: false,
        }))
        .map_err(|e| anyhow!("no GPU adapter: {e}"))?;
        let info = adapter.get_info();
        log::info!("adapter: {} ({:?})", info.name, info.backend);
        let (device, queue) = futures::executor::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("nvs-ide"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
            experimental_features: wgpu::ExperimentalFeatures::disabled(),
            memory_hints: wgpu::MemoryHints::default(),
            trace: wgpu::Trace::Off,
        }))
        .context("request_device")?;

        let caps = surface.get_capabilities(&adapter);
        // Prefer a non-sRGB format: our palette values are then written as-is.
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| !f.is_srgb())
            .or_else(|| caps.formats.first().copied())
            .ok_or_else(|| anyhow!("surface has no formats"))?;
        let srgb = format.is_srgb();
        let mut config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .ok_or_else(|| anyhow!("surface not supported by adapter"))?;
        config.format = format;
        config.present_mode = if caps.present_modes.contains(&wgpu::PresentMode::Mailbox) { wgpu::PresentMode::Mailbox } else { wgpu::PresentMode::Fifo };
        // COPY_SRC lets --screenshot read the presented frame back.
        let can_capture = caps.usages.contains(wgpu::TextureUsages::COPY_SRC);
        if can_capture {
            config.usage |= wgpu::TextureUsages::COPY_SRC;
        }
        surface.configure(&device, &config);

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("cells"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });
        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("cells"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: false }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: false }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::NonFiltering),
                    count: None,
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("cells"),
            bind_group_layouts: &[Some(&bind_group_layout)],
            immediate_size: 0,
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("cells"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Quad>() as u64,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32x2, 2 => Float32x4, 3 => Float32x4, 4 => Uint32],
                })],
            },
            primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleList, ..Default::default() },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("atlas"),
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });
        let globals = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("globals"),
            contents: bytemuck::bytes_of(&Globals { screen_size: [size.width as f32, size.height as f32], srgb_surface: srgb as u32 as f32, _pad: 0.0 }),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let instance_capacity = 16_384;
        let instances = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("instances"),
            size: (instance_capacity * std::mem::size_of::<Quad>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let atlas = Atlas::new(&device);
        let bind_group = Self::make_bind_group(&device, &bind_group_layout, &globals, &atlas, &sampler);
        Ok(Gpu {
            surface,
            device,
            queue,
            config,
            srgb,
            pipeline,
            bind_group_layout,
            bind_group,
            sampler,
            globals,
            instances,
            instance_capacity,
            atlas,
            atlas_generation: 0,
            adapter_name: info.name,
            backend: info.backend,
            can_capture,
        })
    }

    fn make_bind_group(device: &wgpu::Device, layout: &wgpu::BindGroupLayout, globals: &wgpu::Buffer, atlas: &Atlas, sampler: &wgpu::Sampler) -> wgpu::BindGroup {
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("cells"),
            layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: globals.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(atlas.mask_view()) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(atlas.color_view()) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(sampler) },
            ],
        })
    }

    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    pub fn size(&self) -> (u32, u32) {
        (self.config.width, self.config.height)
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        self.config.width = width;
        self.config.height = height;
        self.surface.configure(&self.device, &self.config);
        self.queue.write_buffer(&self.globals, 0, bytemuck::bytes_of(&Globals { screen_size: [width as f32, height as f32], srgb_surface: self.srgb as u32 as f32, _pad: 0.0 }));
    }

    /// Draw the quads over a cleared background and present. Returns false if the surface was
    /// lost and the caller should retry after reconfiguring.
    pub fn render(&mut self, quads: &[Quad], clear: Rgba) -> bool {
        self.render_inner(quads, clear, false).0
    }

    /// Like `render`, and also read the frame back (for `--screenshot` and tests).
    pub fn render_and_capture(&mut self, quads: &[Quad], clear: Rgba) -> (bool, Option<Capture>) {
        self.render_inner(quads, clear, self.can_capture)
    }

    fn render_inner(&mut self, quads: &[Quad], clear: Rgba, capture: bool) -> (bool, Option<Capture>) {
        if self.atlas.generation != self.atlas_generation {
            self.bind_group = Self::make_bind_group(&self.device, &self.bind_group_layout, &self.globals, &self.atlas, &self.sampler);
            self.atlas_generation = self.atlas.generation;
        }
        if quads.len() > self.instance_capacity {
            self.instance_capacity = quads.len().next_power_of_two();
            self.instances = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("instances"),
                size: (self.instance_capacity * std::mem::size_of::<Quad>()) as u64,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
        }
        if !quads.is_empty() {
            self.queue.write_buffer(&self.instances, 0, bytemuck::cast_slice(quads));
        }
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => return (true, None),
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface.configure(&self.device, &self.config);
                return (false, None);
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                log::error!("surface validation error");
                return (false, None);
            }
        };
        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let clear = if self.srgb { linear(clear) } else { clear };
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("frame") });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("cells"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color { r: clear.r as f64, g: clear.g as f64, b: clear.b as f64, a: 1.0 }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            if !quads.is_empty() {
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &self.bind_group, &[]);
                pass.set_vertex_buffer(0, self.instances.slice(..));
                pass.draw(0..6, 0..quads.len() as u32);
            }
        }
        let mut staging = None;
        let (width, height) = (self.config.width, self.config.height);
        let padded_row = (width * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        if capture {
            let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("capture"),
                size: (padded_row * height) as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });
            encoder.copy_texture_to_buffer(
                wgpu::TexelCopyTextureInfo { texture: &frame.texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                wgpu::TexelCopyBufferInfo { buffer: &buffer, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(padded_row), rows_per_image: Some(height) } },
                wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            );
            staging = Some(buffer);
        }
        self.queue.submit(Some(encoder.finish()));
        self.queue.present(frame);
        let captured = staging.map(|buffer| {
            let (tx, rx) = std::sync::mpsc::channel();
            buffer.slice(..).map_async(wgpu::MapMode::Read, move |r| {
                let _ = tx.send(r);
            });
            let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
            let mut rgba = Vec::with_capacity((width * height * 4) as usize);
            if let (Ok(Ok(())), Ok(data)) = (rx.recv(), buffer.slice(..).get_mapped_range()) {
                let bgra = matches!(self.config.format, wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb);
                for row in 0..height {
                    let start = (row * padded_row) as usize;
                    let line = &data[start..start + (width * 4) as usize];
                    if bgra {
                        for px in line.chunks_exact(4) {
                            rgba.extend_from_slice(&[px[2], px[1], px[0], 255]);
                        }
                    } else {
                        for px in line.chunks_exact(4) {
                            rgba.extend_from_slice(&[px[0], px[1], px[2], 255]);
                        }
                    }
                }
                drop(data);
                buffer.unmap();
            }
            Capture { width, height, rgba }
        });
        (true, captured)
    }
}

fn linear(c: Rgba) -> Rgba {
    fn f(v: f32) -> f32 {
        if v <= 0.04045 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    }
    Rgba::new(f(c.r), f(c.g), f(c.b), c.a)
}

/// Text drawing helpers shared by the grid painter and the workbench chrome.
pub struct Painter<'a> {
    pub gpu: &'a mut Gpu,
    pub fonts: &'a mut FontStack,
    pub shaper: &'a mut Shaper,
    pub quads: Vec<Quad>,
}

impl<'a> Painter<'a> {
    pub fn new(gpu: &'a mut Gpu, fonts: &'a mut FontStack, shaper: &'a mut Shaper) -> Self {
        Painter { gpu, fonts, shaper, quads: Vec::with_capacity(8192) }
    }

    pub fn rect(&mut self, x: f32, y: f32, w: f32, h: f32, color: Rgba) {
        if w > 0.0 && h > 0.0 && color.a > 0.0 {
            self.quads.push(Quad::solid(x, y, w, h, color));
        }
    }

    /// Draw a word whose first cell's top-left is at (x, y). Glyphs land on their cells.
    pub fn word(&mut self, word: &Word, x: f32, y: f32, color: Rgba, bold: bool, italic: bool) -> Result<(), AtlasFull> {
        let metrics = self.fonts.metrics();
        let shaped = self.shaper.shape(self.fonts, word);
        let size_q = (metrics.size_px * 4.0) as u32;
        for g in &shaped.glyphs {
            let key = GlyphKey { font: g.font, glyph: g.glyph, size_q, bold, italic };
            let Some(entry) = self.gpu.atlas.get(&self.gpu.device, &self.gpu.queue, self.fonts, key)? else { continue };
            let gx = (x + g.x + entry.left).round();
            let gy = (y + metrics.baseline - g.y - entry.top).round();
            self.quads.push(Quad {
                pos: [gx, gy],
                size: [entry.width, entry.height],
                uv: entry.uv,
                color: if entry.color { [1.0, 1.0, 1.0, color.a] } else { color.to_array() },
                kind: if entry.color { KIND_COLOR } else { KIND_MASK },
                _pad: [0; 3],
            });
        }
        Ok(())
    }

    /// Draw a pixel icon (renderer::icons) with its top-left at (x, y).
    pub fn icon(&mut self, name: &str, x: f32, y: f32, scale: u32, color: Rgba) -> Result<(), AtlasFull> {
        let Some(index) = icons::index_of(name) else { return Ok(()) };
        let key = GlyphKey { font: TILE_FONT, glyph: atlas::ICON_TILE_BASE + index, size_q: scale, bold: false, italic: false };
        let Some(entry) = self.gpu.atlas.get(&self.gpu.device, &self.gpu.queue, self.fonts, key)? else { return Ok(()) };
        self.quads.push(Quad {
            pos: [x.round(), y.round()],
            size: [entry.width, entry.height],
            uv: entry.uv,
            color: color.to_array(),
            kind: KIND_MASK,
            _pad: [0; 3],
        });
        Ok(())
    }

    /// Draw a plain string starting at cell origin (x, y); no shaping cache reuse across
    /// different strings, so use it for chrome text, not the grid.
    pub fn text(&mut self, text: &str, x: f32, y: f32, color: Rgba) -> Result<(), AtlasFull> {
        let mut cluster_sizes = Vec::new();
        let mut owned = String::new();
        for ch in text.chars() {
            owned.push(ch);
            cluster_sizes.push(ch.len_utf8() as u8);
        }
        let word = Word { text: owned, cell: 0, cluster_sizes };
        self.word(&word, x, y, color, false, false)
    }

    pub fn underline(&mut self, style: UnderlineStyle, x: f32, y_baseline: f32, width_cells: u32, color: Rgba) -> Result<(), AtlasFull> {
        let metrics = self.fonts.metrics();
        let cw = metrics.width;
        let stroke = metrics.stroke_size;
        let y = (y_baseline + metrics.underline_offset).round();
        let total = width_cells as f32 * cw;
        match style {
            UnderlineStyle::Underline => self.rect(x, y, total, stroke, color),
            UnderlineStyle::UnderDouble => {
                self.rect(x, y, total, stroke, color);
                self.rect(x, y + 2.0 * stroke, total, stroke, color);
            }
            UnderlineStyle::UnderDash => {
                let dash = 6.0 * stroke;
                let gap = 2.0 * stroke;
                let mut px = 0.0;
                while px < total {
                    self.rect(x + px, y, dash.min(total - px), stroke, color);
                    px += dash + gap;
                }
            }
            UnderlineStyle::UnderDot => {
                let mut px = 0.0;
                while px < total {
                    self.rect(x + px, y, stroke, stroke, color);
                    px += 2.0 * stroke;
                }
            }
            UnderlineStyle::UnderCurl => {
                let key = GlyphKey { font: TILE_FONT, glyph: UNDERCURL_TILE, size_q: (cw * 4.0) as u32, bold: false, italic: false };
                let Some(tile) = self.gpu.atlas.get(&self.gpu.device, &self.gpu.queue, self.fonts, key)? else { return Ok(()) };
                for cell in 0..width_cells {
                    self.quads.push(Quad {
                        pos: [x + cell as f32 * cw, y - stroke],
                        size: [tile.width, tile.height],
                        uv: tile.uv,
                        color: color.to_array(),
                        kind: KIND_MASK,
                        _pad: [0; 3],
                    });
                }
            }
        }
        Ok(())
    }
}

/// Where each window landed, for mouse hit-testing.
pub struct GridLayout {
    pub regions: Vec<WindowRegion>,
}

/// Draw one frame of Neovim's grids with the top-left of grid 1 at `origin`.
/// `cursor_visible` is the blink state. Returns the window regions for the mouse.
pub fn paint_frame(p: &mut Painter, frame: &Frame, origin: (f32, f32), cursor_visible: bool) -> Result<GridLayout, AtlasFull> {
    let metrics = p.fonts.metrics();
    let (cw, ch) = (metrics.width, metrics.height);
    let default_colors = &frame.default_style.colors;
    let default_bg = frame.default_style.background(default_colors);
    let grid_h = frame.grid_size.1 as f32 * ch;
    let mut regions = Vec::with_capacity(frame.windows.len());

    for window in &frame.windows {
        let wx = origin.0 + (window.left as f32 * cw).round();
        let wy = origin.1 + (window.top as f32 * ch).round();
        // Message grids report the full screen height; only the rows down to the bottom edge show.
        let visible_rows = match window.window_type {
            crate::editor::WindowType::Message { .. } => (((origin.1 + grid_h - wy) / ch).floor().max(0.0) as u32).min(window.height),
            _ => window.height,
        };
        regions.push(WindowRegion { id: window.id, x: wx, y: wy, width: window.width as f32 * cw, height: visible_rows as f32 * ch, cols: window.width, rows: visible_rows });
        paint_window(p, window, wx, wy, visible_rows, default_bg, default_colors)?;
    }

    if cursor_visible && frame.cursor.enabled {
        paint_cursor(p, frame, origin)?;
    }
    Ok(GridLayout { regions })
}

fn paint_window(p: &mut Painter, window: &WindowFrame, wx: f32, wy: f32, visible_rows: u32, default_bg: Rgba, default_colors: &crate::editor::Colors) -> Result<(), AtlasFull> {
    let metrics = p.fonts.metrics();
    let (cw, ch) = (metrics.width, metrics.height);
    let draw_all_backgrounds = window.floating || matches!(window.window_type, crate::editor::WindowType::Message { .. });

    // Backgrounds first, whole window, so glyphs never get covered.
    for (row, line) in window.lines.iter().enumerate().take(visible_rows as usize) {
        let y = wy + row as f32 * ch;
        for fragment in &line.fragments {
            let x = wx + fragment.cells.start as f32 * cw;
            let width = (fragment.cells.end - fragment.cells.start) as f32 * cw;
            match &fragment.style {
                Some(style) => {
                    let bg = style.background(default_colors);
                    let alpha = if style.blend > 0 { (100 - style.blend) as f32 / 100.0 } else { 1.0 };
                    if draw_all_backgrounds || bg != default_bg || style.reverse {
                        p.rect(x, y, width, ch, bg.with_alpha(alpha));
                    }
                }
                None if draw_all_backgrounds => p.rect(x, y, width, ch, default_bg),
                None => {}
            }
        }
    }
    for (row, line) in window.lines.iter().enumerate().take(visible_rows as usize) {
        let y = wy + row as f32 * ch;
        for fragment in &line.fragments {
            let x = wx + fragment.cells.start as f32 * cw;
            let (fg, bold, italic, underline, strike, special) = match &fragment.style {
                Some(s) => (s.foreground(default_colors), s.bold, s.italic, s.underline, s.strikethrough, s.special(default_colors)),
                None => (default_colors.foreground.unwrap_or(Rgba::WHITE), false, false, None, false, default_colors.special.unwrap_or(Rgba::WHITE)),
            };
            if let Some(style) = underline {
                p.underline(style, x, y + metrics.baseline, fragment.cells.end - fragment.cells.start, special)?;
            }
            for word in &fragment.words {
                p.word(word, x + word.cell as f32 * cw, y, fg, bold, italic)?;
            }
            if strike {
                let width = (fragment.cells.end - fragment.cells.start) as f32 * cw;
                p.rect(x, (y + ch / 2.0).round(), width, metrics.stroke_size, special);
            }
        }
    }
    Ok(())
}

fn paint_cursor(p: &mut Painter, frame: &Frame, origin: (f32, f32)) -> Result<(), AtlasFull> {
    let cursor = &frame.cursor;
    let Some(window) = frame.windows.iter().find(|w| w.id == cursor.parent_grid) else { return Ok(()) };
    let metrics = p.fonts.metrics();
    let (cw, ch) = (metrics.width, metrics.height);
    let (col, row) = cursor.grid_position;
    let x = origin.0 + ((window.left + col as f64) as f32 * cw).round();
    let y = origin.1 + ((window.top + row as f64) as f32 * ch).round();
    let width = if cursor.double_width { 2.0 * cw } else { cw };
    let (fg, bg) = cursor.colors(&frame.default_style.colors);
    let alpha = cursor.alpha();
    match cursor.shape {
        CursorShape::Block => {
            p.rect(x, y, width, ch, bg.with_alpha(alpha));
            let text = cursor.grid_cell.0.clone();
            if !text.trim().is_empty() {
                let (bold, italic) = cursor.grid_cell.1.as_ref().map(|s| (s.bold, s.italic)).unwrap_or((false, false));
                let word = Word { text: text.clone(), cell: 0, cluster_sizes: vec![text.len() as u8] };
                p.word(&word, x, y, fg, bold, italic)?;
            }
        }
        CursorShape::Vertical => {
            let w = (cw * cursor.cell_percentage.unwrap_or(0.25)).round().max(1.0);
            p.rect(x, y, w, ch, bg.with_alpha(alpha));
        }
        CursorShape::Horizontal => {
            let h = (ch * cursor.cell_percentage.unwrap_or(0.2)).round().max(1.0);
            p.rect(x, y + ch - h, width, h, bg.with_alpha(alpha));
        }
    }
    Ok(())
}
