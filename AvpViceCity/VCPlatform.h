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
///
/// `eye_count` selects how `texture` is laid out, matching the compositor
/// drawable's own shape so both eyes can be drawn in one vertex-amplified pass:
///   1 -> mono: `texture` is a 2D MTLTexture (cinema mode).
///   2 -> stereo: `texture` is a 2D-array MTLTexture with arrayLength 2; slice 0
///        is the left eye, slice 1 the right. `width`/`height` are per-slice.
/// One texture reference (not two): the stereo target is a single array texture,
/// so the compositor binds it as a texture2d_array and indexes slice = viewIndex.
typedef struct vc_ready_frame_t {
    void    *texture;      ///< id<MTLTexture>, opaque (on ANGLE's MTLDevice); 2D or 2D-array
    uint32_t index;        ///< buffer index; pass back to vc_release_frame()
    uint64_t wait_value;   ///< shared-event value to wait for (0 = no wait)
    uint32_t width, height;///< per-slice dimensions
    uint32_t eye_count;    ///< 1 = mono (sample the 2D texture); 2 = stereo (array slice per eye)
    void    *hud_texture;  ///< stereo only: id<MTLTexture>, 2D, the transparent HUD/2D/menu
                           ///<   overlay (SCREEN_WIDTH x SCREEN_HEIGHT), to be drawn as a
                           ///<   head-locked quad over the world slices. NULL in cinema.
    uint64_t pose_set_time;///< mach_absolute_time of the head pose reVC RENDERED this frame
                           ///<   with (== vc_last_pushed_pose_time of that push). The host
                           ///<   matches it to its DeviceAnchor ring and reports THAT anchor
                           ///<   as drawable.deviceAnchor, so the compositor reprojects the
                           ///<   slice from its true render pose (fixes the head-turn double).
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

/// The foveation rasterization rate map (opaque id<MTLRasterizationRateMap>) the eye
/// slices were rendered with, or NULL when VC_FOVEATE is off. The display quad binds its
/// parameter data to unwarp (logical->physical) when sampling the warped slice.
void *vc_foveation_rate_map(void);

/// 1 when foveation is requested (VC_FOVEATE=1). Gate for sampling + pushing the curve.
int vc_foveation_wanted(void);

/// Push the sampled compositor rate curve (per-axis sampling rates, enveloped over both
/// eyes, peak-normalized, floored). The reVC side builds its slice rate map from this and
/// registers it. nx/ny are the per-axis zone counts (2..64).
void vc_set_foveation_curve(const float *h, int nx, const float *v, int ny);

// ---------------------------------------------------------------------------
// Gamepad input (Swift/compositor -> reVC game thread).
// The Swift side reads GCController on the main thread and pushes the latest
// snapshot via vc_set_gamepad_state(); the reVC game thread reads it in
// CapturePad. The buffering + lock live in reVC (src/skel/visionos), which
// mirrors this struct -- the two definitions MUST match. Axes are
// GCController-natural: x right = +1, y up = +1; triggers 0..1. Buttons 0/1.
// ---------------------------------------------------------------------------
typedef struct vc_gamepad_t {
    float   left_x, left_y;              ///< left thumbstick, -1..1 (up = +1)
    float   right_x, right_y;            ///< right thumbstick, -1..1 (up = +1)
    float   left_trigger, right_trigger; ///< L2 / R2, 0..1
    uint8_t south, east, west, north;    ///< A,B,X,Y -> Cross,Circle,Square,Triangle
    uint8_t dpad_up, dpad_down, dpad_left, dpad_right;
    uint8_t left_shoulder, right_shoulder;   ///< L1 / R1
    uint8_t left_thumb, right_thumb;         ///< L3 / R3 (thumbstick click)
    uint8_t menu, options;                   ///< Start / Select
} vc_gamepad_t;

/// Push the latest gamepad snapshot. Called from the Swift main thread; the
/// reVC side buffers it under a lock and reads it on the game thread, so writes
/// here and reads there never overlap. Pass NULL is a no-op.
void vc_set_gamepad_state(const vc_gamepad_t *state);

// ---------------------------------------------------------------------------
// Render mode (cinema vs stereo). Read once from VC_RENDER_MODE at startup:
// default STEREO; only VC_RENDER_MODE=cinema selects the single flat cinema
// screen (comparison/cutscene fallback). The value lives in a mutable global
// (no compile-time bake-in), so a later runtime switch is not precluded. reVC
// mirrors this enum -- keep in sync.
// ---------------------------------------------------------------------------
typedef enum vc_render_mode_t {
    VC_MODE_CINEMA = 0,   ///< single flat render target on a world-anchored quad
    VC_MODE_STEREO = 1,   ///< per-eye stereo render (default)
} vc_render_mode_t;

/// The active (effective) render mode. Readable from both reVC and Swift.
vc_render_mode_t vc_render_mode(void);

/// 1 while the in-game pause menu is up (FrontEndMenuManager.m_bMenuActive), else 0.
/// In stereo the whole in-game render block (world + HUD) is skipped while this is
/// set, so the overlay buffer holds ONLY the menu: the host switches the single
/// overlay quad from head-locked (HUD) to world-anchored (menu) on this flag.
int vc_menu_active(void);

/// 1 while a loading screen / splash is the only thing being rendered (the stereo eye
/// passes are NOT run, so the world slices are stale). The host draws the overlay
/// (cinema/2D buffer = the splash) FULLSCREEN and hides the stale world while set.
int vc_splash_active(void);

/// 1 when verbose perf logging is enabled (env VC_PERF_LOG); gates host-side probes.
int vc_perf_log(void);

/// 1 once the game asked to quit (pause-menu Quit -> RsGlobal.quit). The game thread's
/// loop exits on this, but on visionOS nothing closes the app/immersive space on its own,
/// so the host polls this each frame and dismisses the immersive space when set.
int vc_wants_quit(void);

/// Nudge OpenAL across an AVAudioSession interruption. began=1 pauses the device; began=0
/// resumes + resets the backend so its output AudioUnit restarts (reactivating the session
/// alone leaves it stopped -> silent after the headset is re-donned). Safe to call from the
/// notification thread. No-op before the OpenAL device is open.
void vc_audio_interruption(int began);

/// 1 while a save load is in progress (from confirmation until the world render resumes).
/// The host draws a stable black instead of the frontend/loading screens, which otherwise
/// flicker in stereo (confirm dialog + "please wait" + splash cycling through the buffers).
int vc_loading_active(void);

/// mach_absolute_time of the most recent head pose pushed via vc_set_view_matrix.
/// The host reads this right after pushing so it can key its DeviceAnchor ring to the
/// exact value that later arrives on a buffer as vc_ready_frame_t.pose_set_time.
uint64_t vc_last_pushed_pose_time(void);

// ---------------------------------------------------------------------------
// Camera matrix override (stereo injection point). When the override is active,
// reVC's gl3device beginUpdate uploads THESE matrices to the shader uniforms
// instead of the ones it computed from RwCamera. With the flag off, nothing
// changes. Matrices are 16 floats, COLUMN-MAJOR, in librw's convention:
// left-handed view space looking down +Z, clip depth -1..1. (CompositorServices
// matrices are right-handed / -Z / depth 0..1 and will need converting BEFORE
// being passed here -- that conversion is a later step, not done by these
// setters.) Buffered under a lock on the reVC side; safe to call cross-thread.
// ---------------------------------------------------------------------------
void vc_set_view_matrix(const float m[16]);
void vc_set_projection_matrix(const float m[16]);
void vc_set_matrix_override(int active);

/// View compose mode. When on AND the override is active, reVC treats the view
/// matrix above as a head-pose OFFSET and left-multiplies it onto the game's own
/// view (V_final = offset * V_game) instead of replacing it -- so the game
/// camera is preserved and the head pose only adds a look-around on top. Off =
/// replace (used by the matrix self-test). Head tracking sets this on.
void vc_set_view_compose(int on);

// ---------------------------------------------------------------------------
// Per-eye stereo matrices (Swift -> reVC game thread). Swift pushes the real
// CompositorServices eye view + projection matrices ONCE PER FRAME, ALREADY
// CONVERTED to librw convention (left-handed / +Z eye / clip depth -1..1,
// column-major simd), by the SAME F/D basis change the head-pose setters above
// use. Buffered under a lock; the game thread reads the latest via the getter.
//
// Translations are in METRES (compositor units) -- deliberately NOT scaled to
// Vice City game units, so the logged eye separation reads the true ~0.06 m.
// The metres->game-units scale and how these compose with the game camera are
// the RENDER PATH's job (a later step), not this seam's.
//
// Cinema does NOT populate this: `valid` stays 0 and the getter returns false,
// so the eye passes keep their current behaviour until the render path consumes
// it. eyes[0] = left, eyes[1] = right (matching the drawable's view order).
// ---------------------------------------------------------------------------
typedef struct vc_stereo_eye_matrices_t {
    simd_float4x4 view[2];        ///< world->eye, librw convention, metres
    simd_float4x4 projection[2];  ///< librw clip, depth -1..1
    uint32_t      valid;          ///< 0 = not populated (cinema); 1 = valid stereo
} vc_stereo_eye_matrices_t;

/// Push the latest per-eye matrices. Called from the Swift render thread once per
/// stereo frame; buffered under a lock. Passing NULL is a no-op.
void vc_set_stereo_eye_matrices(const vc_stereo_eye_matrices_t *eyes);

/// Read the latest per-eye matrices (reVC game thread). Returns false and leaves
/// `out` untouched if none were ever pushed (cinema / not yet available), so the
/// caller can fall back to its current behaviour.
bool vc_get_stereo_eye_matrices(vc_stereo_eye_matrices_t *out);

#ifdef __cplusplus
}
#endif

#endif /* VCPlatform_h */
