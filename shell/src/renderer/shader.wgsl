// One pipeline for everything the shell draws: solid rectangles, glyphs from the mask atlas,
// and colour glyphs (emoji) from the RGBA atlas. Each instance is one axis-aligned quad.

struct Globals {
    screen_size: vec2<f32>,
    // 1.0 when the surface is an sRGB format and colours must be linearised first.
    srgb_surface: f32,
    _pad: f32,
};

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var mask_atlas: texture_2d<f32>;
@group(0) @binding(2) var color_atlas: texture_2d<f32>;
@group(0) @binding(3) var atlas_sampler: sampler;

struct Instance {
    @location(0) pos: vec2<f32>,
    @location(1) size: vec2<f32>,
    @location(2) uv: vec4<f32>,
    @location(3) color: vec4<f32>,
    @location(4) kind: u32,
};

struct VertexOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) @interpolate(flat) kind: u32,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, inst: Instance) -> VertexOut {
    // Two triangles: 0,1,2 and 2,1,3 over the unit square.
    let corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
        vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
    );
    let c = corners[vi];
    let px = inst.pos + c * inst.size;
    let ndc = vec2<f32>(px.x / globals.screen_size.x * 2.0 - 1.0, 1.0 - px.y / globals.screen_size.y * 2.0);
    var out: VertexOut;
    out.clip = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = mix(inst.uv.xy, inst.uv.zw, c);
    out.color = inst.color;
    out.kind = inst.kind;
    return out;
}

fn to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + 0.055) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    var rgb = in.color.rgb;
    var alpha = in.color.a;
    if (in.kind == 1u) {
        // Glyph mask: the atlas holds coverage in the red channel.
        alpha = alpha * textureSample(mask_atlas, atlas_sampler, in.uv).r;
    } else if (in.kind == 2u) {
        let texel = textureSample(color_atlas, atlas_sampler, in.uv);
        rgb = texel.rgb;
        alpha = alpha * texel.a;
    }
    if (globals.srgb_surface > 0.5) {
        rgb = to_linear(rgb);
    }
    return vec4<f32>(rgb * alpha, alpha);
}
