//
//  VCTriangle.metal
//  AvpViceCity
//
//  Shader for the C++/Metal boundary's draw: a single, world-anchored triangle
//  rendered for BOTH eyes in one vertex-amplified pass. The vertex positions are
//  supplied in WORLD space and transformed by the per-eye view and projection
//  matrices that cross the VCPlatform boundary, so the triangle stays put as the
//  head moves.
//

#include <metal_stdlib>
using namespace metal;

// Per-eye matrices. Must match `VCEyeUniforms` in VCRendererStub.mm.
struct VCEyeUniforms {
    float4x4 view;
    float4x4 projection;
};

// Both eyes in one buffer, indexed by [[amplification_id]]. Must match
// `VCTriangleUniforms` in VCRendererStub.mm.
struct VCTriangleUniforms {
    VCEyeUniforms eyes[2];
};

struct VCTriangleVertexOut {
    float4 position [[position]];
    // No render_target_array_index / viewport_array_index outputs here: with
    // vertex amplification, both are supplied per amplification by the encoder's
    // MTLVertexAmplificationViewMapping (offsets), not written by the shader.
};

vertex VCTriangleVertexOut vc_triangle_vertex(uint vertexID [[vertex_id]],
                                              ushort amplificationID [[amplification_id]],
                                              const device packed_float3 *positions [[buffer(0)]],
                                              constant VCTriangleUniforms &uniforms [[buffer(1)]]) {
    VCTriangleVertexOut out;
    // Pick this amplification's eye, then world -> eye (view) -> clip (projection).
    constant VCEyeUniforms &eye = uniforms.eyes[amplificationID];
    float4 worldPosition = float4(positions[vertexID], 1.0);
    out.position = eye.projection * eye.view * worldPosition;
    return out;
}

fragment float4 vc_triangle_fragment(VCTriangleVertexOut in [[stage_in]]) {
    // Solid opaque orange so it is obvious over the host's cube.
    return float4(1.0, 0.5, 0.0, 1.0);
}
