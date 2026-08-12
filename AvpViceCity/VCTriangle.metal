//
//  VCTriangle.metal
//  AvpViceCity
//
//  Shader for the C++/Metal boundary's first real draw: a single, world-anchored
//  triangle rendered once per eye. The vertex positions are supplied in WORLD
//  space and transformed by the per-eye view and projection matrices that cross
//  the VCPlatform boundary, so the triangle stays put as the head moves.
//

#include <metal_stdlib>
using namespace metal;

// Must match `VCTriangleUniforms` in VCRendererStub.mm (column-major float4x4).
struct VCTriangleUniforms {
    float4x4 view;
    float4x4 projection;
    uint slice;
};

struct VCTriangleVertexOut {
    float4 position [[position]];
    // Routes this vertex's primitive to the eye's texture-array slice without
    // vertex amplification (one draw call per eye sets `slice`).
    uint layer [[render_target_array_index]];
};

vertex VCTriangleVertexOut vc_triangle_vertex(uint vertexID [[vertex_id]],
                                              const device packed_float3 *positions [[buffer(0)]],
                                              constant VCTriangleUniforms &uniforms [[buffer(1)]]) {
    VCTriangleVertexOut out;
    // World-space position -> eye space (view) -> clip space (projection).
    float4 worldPosition = float4(positions[vertexID], 1.0);
    out.position = uniforms.projection * uniforms.view * worldPosition;
    out.layer = uniforms.slice;
    return out;
}

fragment float4 vc_triangle_fragment(VCTriangleVertexOut in [[stage_in]]) {
    // Solid opaque orange so it is obvious over the host's cube.
    return float4(1.0, 0.5, 0.0, 1.0);
}
