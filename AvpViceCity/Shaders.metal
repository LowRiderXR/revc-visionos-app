//
//  Shaders.metal
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

// ---------------------------------------------------------------------------
// World-anchored quad that shows the reVC/ANGLE game texture. Both eyes in one
// vertex-amplified pass, same convention as VCTriangle. Positions are supplied
// in WORLD space; the shader applies the per-eye view-projection so the quad
// stays put as the head moves.
// ---------------------------------------------------------------------------
struct VCQuadVertex {
    packed_float3 position;   // world space
    packed_float2 uv;
};

// One view-projection matrix per eye, indexed by [[amplification_id]].
struct VCQuadUniforms {
    float4x4 viewProjection[2];
};

struct VCQuadInOut {
    float4 position [[position]];
    float2 uv;
};

vertex VCQuadInOut vc_quad_vertex(uint vertexID [[vertex_id]],
                                  ushort amplificationID [[amplification_id]],
                                  const device VCQuadVertex *verts [[buffer(0)]],
                                  constant VCQuadUniforms &uniforms [[buffer(1)]])
{
    VCQuadInOut out;
    float4 world = float4(verts[vertexID].position, 1.0);
    out.position = uniforms.viewProjection[amplificationID] * world;
    out.uv = verts[vertexID].uv;
    return out;
}

// The game texture is RGBA8Unorm holding gamma-encoded (sRGB) values, sampled
// raw (no sRGB texture view: the source lacks MTLTextureUsagePixelFormatView).
// The drawable is linear RGBA16Float, so decode sRGB -> linear here; otherwise
// the image comes out washed out and too bright.
static float3 vc_srgb_to_linear(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
    return select(lo, hi, c > 0.04045);
}

fragment float4 vc_quad_fragment(VCQuadInOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);
    return float4(vc_srgb_to_linear(c.rgb), c.a);
}

// ---------------------------------------------------------------------------
// Solid-colour stats bars (VC_DEBUG_STATS). Same world-space + amplification
// convention as the quad; colour is a per-draw fragment constant (linear RGB).
// ---------------------------------------------------------------------------
struct VCBarVP {
    float4x4 viewProjection[2];
};

struct VCBarInOut {
    float4 position [[position]];
};

vertex VCBarInOut vc_bar_vertex(uint vertexID [[vertex_id]],
                                ushort amplificationID [[amplification_id]],
                                const device packed_float3 *positions [[buffer(0)]],
                                constant VCBarVP &vp [[buffer(1)]])
{
    VCBarInOut out;
    out.position = vp.viewProjection[amplificationID] * float4(positions[vertexID], 1.0);
    return out;
}

fragment float4 vc_bar_fragment(constant float4 &color [[buffer(0)]])
{
    return color;
}
