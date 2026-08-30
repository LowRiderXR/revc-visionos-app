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
// Stereo path (PROJECTED SCREEN). The game hands over a 2D-ARRAY texture (slice
// 0 = left eye, slice 1 = right), each slice rendered from that eye's camera
// (symmetric projection + IPD offset on the C side). This draws the SAME world-
// anchored quad as the cinema path -- one per-eye view-projection so both eyes
// CONVERGE on a common virtual screen -- but each eye samples its own array
// slice ([[amplification_id]] -> slice i, routed to drawable slice i, not
// swapped). The per-eye image disparity gives the 3D; the shared screen gives
// the convergence. A non-projected full-screen blit could NOT fuse: with the
// eyes' asymmetric (canted) FOVs, two screen-filling images have no common world
// point to converge on -- proven on device (even two identical slices diverged).
struct VCStereoInOut {
    float4 position [[position]];
    float2 uv;
    ushort eye [[flat]];
};

vertex VCStereoInOut vc_stereo_vertex(uint vertexID [[vertex_id]],
                                      ushort amplificationID [[amplification_id]],
                                      const device VCQuadVertex *verts [[buffer(0)]],
                                      constant VCQuadUniforms &uniforms [[buffer(1)]])
{
    VCStereoInOut out;
    float4 world = float4(verts[vertexID].position, 1.0);   // world space (as cinema)
    out.position = uniforms.viewProjection[amplificationID] * world;
    out.uv = verts[vertexID].uv;
    out.eye = amplificationID;
    return out;
}

fragment float4 vc_stereo_fragment(VCStereoInOut in [[stage_in]],
                                   texture2d_array<float> tex [[texture(0)]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    // uv.x MIRRORED: ANGLE's GL-render into a per-slice array EGLImage arrives
    // horizontally flipped in the Metal texture (measured via slice probe). The
    // cinema 2D path is not flipped, hence only the array path compensates here.
    float2 uv = float2(1.0 - in.uv.x, in.uv.y);
    float4 c = tex.sample(s, uv, in.eye);
    return float4(vc_srgb_to_linear(c.rgb), c.a);
}

// Diagnostic (VC_STEREO_TESTFILL=1): ignore the texture, paint eye 0 red / eye 1
// green. Proves the full-screen triangle rasterizes, the pipeline runs, and the
// amplification routes each eye to its slice -- isolating "pass broken" from
// "sampling broken", and revealing a left/right swap.
fragment float4 vc_stereo_fragment_testfill(VCStereoInOut in [[stage_in]])
{
    return in.eye == 0 ? float4(1.0, 0.0, 0.0, 1.0) : float4(0.0, 1.0, 0.0, 1.0);
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
