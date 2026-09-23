//
//  MultiviewSpike.metal
//  Stufe 1 of the multiview plan: shader for the standalone spike pass.
//  Draws colored bars given in LOGICAL pixels; layer 1 (amplification_id == 1)
//  shifts all geometry by params.zw so the two slices are distinguishable.
//

#include <metal_stdlib>
using namespace metal;

struct MVSpikeVertexIn {
    packed_float2 pos;    // logical pixels, origin top-left
    packed_float4 color;
};

struct MVSpikeVaryings {
    float4 position [[position]];
    float4 color;
};

vertex MVSpikeVaryings mv_spike_vertex(uint vid [[vertex_id]],
                                       ushort amp [[amplification_id]],
                                       const device MVSpikeVertexIn *verts [[buffer(0)]],
                                       constant float4 &params [[buffer(1)]])
{
    // params.xy = logical screen size, params.zw = per-layer shift in logical px
    MVSpikeVertexIn v = verts[vid];
    float2 p = float2(v.pos) + float(amp) * params.zw;
    float2 ndc = float2(p.x / params.x * 2.0 - 1.0,
                        1.0 - p.y / params.y * 2.0);
    MVSpikeVaryings out;
    out.position = float4(ndc, 0.5, 1.0);
    out.color = float4(v.color);
    return out;
}

fragment float4 mv_spike_fragment(MVSpikeVaryings in [[stage_in]])
{
    return in.color;
}
