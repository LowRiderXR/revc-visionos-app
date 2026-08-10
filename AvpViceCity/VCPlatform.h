//
//  VCPlatform.h
//  AvpViceCity
//
//  Plain-C boundary between the Swift/CompositorServices host and the future
//  C++ game-engine renderer. This header is intentionally free of any
//  Objective-C, Swift, or Metal headers: all Metal objects cross the boundary
//  as opaque `void *` handles so the same header can later be included
//  unchanged from the C++ codebase.
//

#ifndef VCPlatform_h
#define VCPlatform_h

#include <simd/simd.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// View and projection matrices for a single eye, plus the texture array
/// slice (render-target array index) that eye renders into.
typedef struct vc_eye_t {
    simd_float4x4 view;
    simd_float4x4 projection;
    uint32_t slice;
} vc_eye_t;

/// Everything the renderer needs to draw one CompositorServices frame. All
/// Metal objects are opaque handles: `color_texture` / `depth_texture` /
/// `rate_map` are `id<MTLTexture>` / `id<MTLRasterizationRateMap>`,
/// `command_buffer` is `id<MTLCommandBuffer>`. `rate_map` may be NULL.
typedef struct vc_frame_t {
    vc_eye_t eyes[2];
    uint32_t eye_count;
    void *color_texture;
    void *depth_texture;
    void *rate_map;
    void *command_buffer;
    double presentation_time;
} vc_frame_t;

/// Initialize the renderer with the Metal device (an opaque `id<MTLDevice>`).
/// Returns true on success. Call once.
bool vc_renderer_init(void *mtl_device);

/// Render a single frame. `frame` is owned by the caller for the duration of
/// the call. Call once per frame.
void vc_renderer_render(const vc_frame_t *frame);

/// Tear down the renderer and release any resources it holds.
void vc_renderer_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* VCPlatform_h */
