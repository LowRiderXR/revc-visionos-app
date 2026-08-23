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

// ---------------------------------------------------------------------------
// Game -> compositor hand-off (double-buffered reVC render target).
// The reVC game thread renders into one of two shared MTLTextures and publishes
// it; the compositor acquires the latest finished one, waits on a Metal shared
// event for `wait_value` before sampling, then releases it back. This struct
// and these prototypes are the "C seam"; the definitions live in reVC
// (src/skel/visionos) and MUST match the mirror struct there.
// ---------------------------------------------------------------------------

/// A finished render-target buffer ready for the compositor.
typedef struct vc_ready_frame_t {
    void    *texture;      ///< id<MTLTexture>, opaque (on ANGLE's MTLDevice)
    uint32_t index;        ///< buffer index; pass back to vc_release_frame()
    uint64_t wait_value;   ///< shared-event value to wait for (0 = no wait)
    uint32_t width, height;
} vc_ready_frame_t;

/// Non-blocking. Fills `out` with the most recently finished buffer and returns
/// true; returns false if nothing is ready yet. The compositor owns that buffer
/// until it calls vc_release_frame(out->index) — without the release the waiting
/// game thread never gets the buffer back.
bool vc_acquire_ready_frame(vc_ready_frame_t *out);

/// Return a buffer to the game thread (unblocks it if it was waiting).
void vc_release_frame(uint32_t index);

/// The shared MTLSharedEvent (opaque id<MTLSharedEvent>) for cross-API sync.
/// Call once; NULL if the shared-event path is unavailable (fallback in use).
void *vc_get_shared_event(void);

#ifdef __cplusplus
}
#endif

#endif /* VCPlatform_h */
