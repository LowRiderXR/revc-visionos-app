//
//  VCRendererStub.mm
//  AvpViceCity
//
//  Minimal but real Metal renderer behind the VCPlatform boundary. It draws a
//  single, world-anchored triangle for both eyes in one vertex-amplified pass,
//  into the colour/depth textures the Swift host hands over each frame. It never
//  creates or commits a command
//  buffer and never presents — the Swift host still owns submission. The
//  existing throttled diagnostics are kept.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <os/lock.h>
#import <math.h>

#import "VCPlatform.h"

// Per-eye matrices. Must match `VCEyeUniforms` in VCTriangle.metal.
typedef struct {
    simd_float4x4 view;
    simd_float4x4 projection;
} VCEyeUniforms;

// Both eyes uploaded once; indexed by [[amplification_id]] in the shader.
// Must match `VCTriangleUniforms` in VCTriangle.metal.
typedef struct {
    VCEyeUniforms eyes[2];
} VCTriangleUniforms;

// Cached GPU resources — built once, never rebuilt per frame.
static id<MTLDevice> gDevice = nil;
static id<MTLRenderPipelineState> gPipeline = nil;
static id<MTLDepthStencilState> gDepthState = nil;
static id<MTLBuffer> gVertexBuffer = nil;
static id<MTLFunction> gVertexFunction = nil;
static id<MTLFunction> gFragmentFunction = nil;
static bool gPipelineFailed = false;

extern "C" bool psInitialize(void);
extern "C" void vc_game_thread_start(void); // starts reVC's game loop on its own thread

bool vc_renderer_init(void *mtl_device) {
    if (mtl_device == NULL) {
        NSLog(@"[vc] init failed: null Metal device");
        return false;
    }

    // Bridge the opaque handle back to its ARC type; the strong static keeps
    // the device alive for the renderer's lifetime.
    id<MTLDevice> device = (__bridge id<MTLDevice>)mtl_device;
    NSLog(@"[vc] init with device %p (name: %@)", (__bridge void *)device, device.name);
    gDevice = device;

    // A single triangle, positioned in WORLD space: ~0.5 m across, centred
    // 1.5 m in front of the world origin (-Z is forward) at ~eye height. The
    // world origin sits at the FLOOR in this app (per-frame view.translation.y
    // shows the eyes ~1.15 m above the origin), so eye height is Y ≈ 1.15 m,
    // not 0. Because the positions are world-space and the shader applies the
    // per-eye view matrix, the triangle is world-anchored, not head-locked.
    static const float kTriangleVertices[9] = {
        -0.25f, 0.90f, -1.5f,
         0.25f, 0.90f, -1.5f,
         0.00f, 1.40f, -1.5f,
    };
    gVertexBuffer = [device newBufferWithBytes:kTriangleVertices
                                        length:sizeof(kTriangleVertices)
                                       options:MTLResourceStorageModeShared];
    if (gVertexBuffer == nil) {
        NSLog(@"[vc] init failed: could not create triangle vertex buffer");
        return false;
    }
    gVertexBuffer.label = @"vc.triangle.vertices";

    // Shader functions live in the app's default library (VCTriangle.metal is
    // compiled into the same target).
    id<MTLLibrary> library = [device newDefaultLibrary];
    if (library == nil) {
        NSLog(@"[vc] init failed: no default Metal library");
        return false;
    }
    gVertexFunction = [library newFunctionWithName:@"vc_triangle_vertex"];
    gFragmentFunction = [library newFunctionWithName:@"vc_triangle_fragment"];
    if (gVertexFunction == nil || gFragmentFunction == nil) {
        NSLog(@"[vc] init failed: missing triangle shader functions (vertex=%p fragment=%p)",
              (__bridge void *)gVertexFunction, (__bridge void *)gFragmentFunction);
        return false;
    }

    // Reverse-Z depth (greater) with writes enabled, matching the host so the
    // triangle depth-tests correctly against the cube.
    MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc.depthCompareFunction = MTLCompareFunctionGreater;
    depthDesc.depthWriteEnabled = YES;
    gDepthState = [device newDepthStencilStateWithDescriptor:depthDesc];
    if (gDepthState == nil) {
        NSLog(@"[vc] init failed: could not create depth-stencil state");
        return false;
    }

    // in vc_renderer_init, nach dem bestehenden Logging:
    NSLog(@"[vc] calling psInitialize...");
    bool ok = psInitialize();
    NSLog(@"[vc] psInitialize returned %d", ok);
    // Start reVC's game-state loop on its own thread once init succeeded. It
    // claims the GL context that psInitialize released before returning.
    if (ok) vc_game_thread_start();

    // NOTE: the render pipeline state itself is created lazily on the first
    // render call. It needs the drawable's colour/depth pixel formats, which
    // are only available from the per-frame textures — vc_renderer_init only
    // receives the device. It is still cached and built exactly once.
    return true;
}

// Build the triangle pipeline on demand from the drawable's pixel formats.
// Returns true when a usable pipeline is available.
static bool vc_build_pipeline_if_needed(id<MTLTexture> colorTexture, id<MTLTexture> depthTexture) {
    if (gPipeline != nil) {
        return true;
    }
    if (gPipelineFailed || gDevice == nil || gVertexFunction == nil || gFragmentFunction == nil) {
        return false;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.label = @"vc.triangle";
    desc.vertexFunction = gVertexFunction;
    desc.fragmentFunction = gFragmentFunction;
    // The drawable colour/depth textures are single-sample (MSAA, if any, is
    // already resolved into them by the host), so this baseline is 1x.
    desc.rasterSampleCount = 1;
    // Both eyes are produced in a single pass via vertex amplification. The
    // shader no longer writes render_target_array_index, so inputPrimitiveTopology
    // is not required here.
    desc.maxVertexAmplificationCount = 2;
    desc.colorAttachments[0].pixelFormat = colorTexture.pixelFormat;
    desc.depthAttachmentPixelFormat = depthTexture.pixelFormat;

    NSError *error = nil;
    gPipeline = [gDevice newRenderPipelineStateWithDescriptor:desc error:&error];
    if (gPipeline == nil) {
        gPipelineFailed = true;
        NSLog(@"[vc] failed to create triangle pipeline state: %@", error);
        return false;
    }
    NSLog(@"[vc] triangle pipeline ready (colorFormat=%lu depthFormat=%lu)",
          (unsigned long)colorTexture.pixelFormat, (unsigned long)depthTexture.pixelFormat);
    return true;
}

// The test triangle is a diagnostic: it proves the compositor pass draws at all
// and that vertex amplification + the rate map still apply, and gives Phase 5 an
// object at a known position. Off by default (it sits in front of the screen);
// enable with VC_DEBUG_TRIANGLE=1. Read once.
static bool vc_debug_triangle_enabled(void) {
    static bool cached = false;
    static bool initialized = false;
    if (!initialized) {
        const char *v = getenv("VC_DEBUG_TRIANGLE");
        cached = (v != NULL && v[0] == '1');
        initialized = true;
        NSLog(@"[vc] debug triangle %s (VC_DEBUG_TRIANGLE)", cached ? "ENABLED" : "disabled");
    }
    return cached;
}

void vc_renderer_render(const vc_frame_t *frame) {
    if (frame == NULL) {
        return;
    }

    // Bridge the opaque per-frame Metal handles back to their ARC types.
    id<MTLTexture> colorTexture = (__bridge id<MTLTexture>)frame->color_texture;
    id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)frame->depth_texture;
    id<MTLRasterizationRateMap> rateMap = (__bridge id<MTLRasterizationRateMap>)frame->rate_map;
    id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)frame->command_buffer;

    // --- Encode the world-anchored triangle, both eyes in one pass ----------
    // Diagnostic only; off unless VC_DEBUG_TRIANGLE=1 (see above).
    if (vc_debug_triangle_enabled() &&
        commandBuffer != nil && colorTexture != nil && depthTexture != nil &&
        vc_build_pipeline_if_needed(colorTexture, depthTexture)) {

        // ---- Decide rate-map usage (read fresh every frame; never cached) ---
        // A rasterization rate map remaps a LOGICAL (screen-size) viewport into
        // the smaller physical render target. Attach it only if the colour
        // texture is at least as large as the map's physical size for every
        // layer we render into; a stale/mismatched map warps silently (no error
        // from Metal), so on mismatch we fall back to the unfoveated path.
        id<MTLRasterizationRateMap> rateMapToUse = nil;
        MTLSize rateScreenSize = (MTLSize){0, 0, 0};
        MTLSize ratePhysicalSize = (MTLSize){0, 0, 0}; // layer 0, for logging

        const uint32_t eyesUsed = frame->eye_count < 2 ? frame->eye_count : 2;

        if (rateMap != nil) {
            rateScreenSize = rateMap.screenSize;
            const NSUInteger layerCount = rateMap.layerCount;
            bool fits = (layerCount >= eyesUsed);
            for (uint32_t i = 0; i < eyesUsed && i < layerCount; i++) {
                MTLSize phys = [rateMap physicalSizeForLayer:i];
                if (i == 0) { ratePhysicalSize = phys; }
                if (colorTexture.width < phys.width || colorTexture.height < phys.height) {
                    fits = false;
                }
            }
            if (fits) {
                rateMapToUse = rateMap;
            }
        }

        // Log the rate-map state on the first call and whenever it changes
        // (never per frame, never silent).
        {
            static bool sInitialized = false;
            static bool sHadRateMap = false;
            static bool sAttached = false;
            static NSUInteger sScreenW = 0, sScreenH = 0, sPhysW = 0, sPhysH = 0;

            const bool hadRateMap = (rateMap != nil);
            const bool attached = (rateMapToUse != nil);
            if (!sInitialized || hadRateMap != sHadRateMap || attached != sAttached ||
                rateScreenSize.width != sScreenW || rateScreenSize.height != sScreenH ||
                ratePhysicalSize.width != sPhysW || ratePhysicalSize.height != sPhysH) {
                if (!hadRateMap) {
                    NSLog(@"[vc] rate map: none (null) -> unfoveated fallback, viewport = texture %lux%lu",
                          (unsigned long)colorTexture.width, (unsigned long)colorTexture.height);
                } else if (attached) {
                    NSLog(@"[vc] rate map: ATTACHED screenSize=%lux%lu physicalSize(layer0)=%lux%lu (viewport = screenSize)",
                          (unsigned long)rateScreenSize.width, (unsigned long)rateScreenSize.height,
                          (unsigned long)ratePhysicalSize.width, (unsigned long)ratePhysicalSize.height);
                } else {
                    NSLog(@"[vc] rate map: MISMATCH screenSize=%lux%lu physicalSize(layer0)=%lux%lu vs color texture %lux%lu -> NOT attached, unfoveated fallback",
                          (unsigned long)rateScreenSize.width, (unsigned long)rateScreenSize.height,
                          (unsigned long)ratePhysicalSize.width, (unsigned long)ratePhysicalSize.height,
                          (unsigned long)colorTexture.width, (unsigned long)colorTexture.height);
                }
                sInitialized = true;
                sHadRateMap = hadRateMap;
                sAttached = attached;
                sScreenW = rateScreenSize.width; sScreenH = rateScreenSize.height;
                sPhysW = ratePhysicalSize.width; sPhysH = ratePhysicalSize.height;
            }
        }

        MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        // loadAction .load: keep whatever the Swift renderer already drew.
        passDescriptor.colorAttachments[0].texture = colorTexture;
        passDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
        passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDescriptor.depthAttachment.texture = depthTexture;
        passDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
        passDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
        if (rateMapToUse != nil) {
            passDescriptor.rasterizationRateMap = rateMapToUse;
        }
        // Layered render target: vertex amplification routes each eye to its
        // own slice via the view mapping's renderTargetArrayIndexOffset.
        passDescriptor.renderTargetArrayLength = frame->eye_count;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
        encoder.label = @"vc.triangle";
        [encoder setRenderPipelineState:gPipeline];
        [encoder setDepthStencilState:gDepthState];
        [encoder setCullMode:MTLCullModeNone];

        // With the rate map attached, the viewport is in LOGICAL (screen)
        // coordinates and the map compresses to the physical render target;
        // otherwise (null or size mismatch) it maps 1:1 to the physical texture.
        MTLViewport viewport;
        if (rateMapToUse != nil) {
            viewport = (MTLViewport){0.0, 0.0, (double)rateScreenSize.width, (double)rateScreenSize.height, 0.0, 1.0};
        } else {
            viewport = (MTLViewport){0.0, 0.0, (double)colorTexture.width, (double)colorTexture.height, 0.0, 1.0};
        }
        [encoder setViewport:viewport];
        [encoder setVertexBuffer:gVertexBuffer offset:0 atIndex:0];

        // Vertex amplification: produce both eyes in ONE draw call. Amplification
        // i routes to its eye's texture-array slice via the view mapping's
        // renderTargetArrayIndexOffset; both share the single viewport (offset 0).
        const uint32_t eyeCount = frame->eye_count < 2 ? frame->eye_count : 2;

        VCTriangleUniforms uniforms;
        for (uint32_t i = 0; i < eyeCount; i++) {
            uniforms.eyes[i].view = frame->eyes[i].view;
            uniforms.eyes[i].projection = frame->eyes[i].projection;
        }
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];

        MTLVertexAmplificationViewMapping viewMappings[2];
        for (uint32_t i = 0; i < eyeCount; i++) {
            viewMappings[i].renderTargetArrayIndexOffset = frame->eyes[i].slice;
            viewMappings[i].viewportArrayIndexOffset = 0;
        }
        [encoder setVertexAmplificationCount:eyeCount viewMappings:viewMappings];

        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

        [encoder endEncoding];
    }

    // --- Throttled diagnostics ---------------------------------------------
    // Verify the data crossing the C boundary. Logs once every 90 frames, plus
    // a one-time texture description on the very first call.
    static uint64_t vcFrameCounter = 0;
    static double vcLastLoggedPresentationTime = 0.0;
    static bool vcHaveLoggedBefore = false;

    const uint64_t currentFrame = vcFrameCounter++;

    if (currentFrame == 0) {
        // One-time description of the colour texture and rate-map presence.
        NSLog(@"[vc] first call: color texture %lux%lu pixelFormat=%lu arrayLength=%lu rateMap=%s",
              (unsigned long)colorTexture.width,
              (unsigned long)colorTexture.height,
              (unsigned long)colorTexture.pixelFormat,
              (unsigned long)colorTexture.arrayLength,
              frame->rate_map == NULL ? "null" : "non-null");
    }

    if ((currentFrame % 90) != 0) {
        return;
    }

    // Mean frame interval since the previous logged frame, averaged over the
    // 90 frames that elapsed between logs.
    double meanFrameInterval = 0.0;
    if (vcHaveLoggedBefore) {
        meanFrameInterval = (frame->presentation_time - vcLastLoggedPresentationTime) / 90.0;
    }
    vcLastLoggedPresentationTime = frame->presentation_time;
    vcHaveLoggedBefore = true;

    NSLog(@"[vc] frame %llu: eye_count=%u color=%p depth=%p rateMap=%p cmdBuffer=%p",
          (unsigned long long)currentFrame,
          frame->eye_count,
          frame->color_texture,
          frame->depth_texture,
          frame->rate_map,
          frame->command_buffer);

    NSLog(@"[vc] frame %llu: presentation_time=%.4f mean_frame_interval=%.4f s",
          (unsigned long long)currentFrame,
          frame->presentation_time,
          meanFrameInterval);

    const uint32_t loggedEyeCount = frame->eye_count < 2 ? frame->eye_count : 2;
    for (uint32_t i = 0; i < loggedEyeCount; i++) {
        const vc_eye_t eye = frame->eyes[i];
        NSLog(@"[vc] frame %llu eye %u: slice=%u view.translation=(%.4f, %.4f, %.4f)",
              (unsigned long long)currentFrame, i, eye.slice,
              eye.view.columns[3].x, eye.view.columns[3].y, eye.view.columns[3].z);
        // First row of the (column-major) projection matrix.
        NSLog(@"[vc] frame %llu eye %u: proj.row0=(%.4f, %.4f, %.4f, %.4f)",
              (unsigned long long)currentFrame, i,
              eye.projection.columns[0].x, eye.projection.columns[1].x,
              eye.projection.columns[2].x, eye.projection.columns[3].x);
    }

    // Derived check: horizontal separation between the two eyes' view
    // translations. This is the value to verify.
    if (frame->eye_count >= 2) {
        float dx = frame->eyes[0].view.columns[3].x - frame->eyes[1].view.columns[3].x;
        if (dx < 0.0f) { dx = -dx; }
        NSLog(@"[vc] frame %llu: eye separation=%.4f", (unsigned long long)currentFrame, dx);
    }
}

void vc_renderer_shutdown(void) {
    NSLog(@"[vc] shutdown");
    gPipeline = nil;
    gDepthState = nil;
    gVertexBuffer = nil;
    gVertexFunction = nil;
    gFragmentFunction = nil;
    gDevice = nil;
}

// ---------------------------------------------------------------------------
// Per-eye stereo matrices seam (Swift render thread -> reVC game thread).
// Latest-wins under a lock: the Swift side overwrites the whole struct once per
// frame, the game thread reads the newest snapshot. Zero-initialised, so `valid`
// is 0 (cinema / nothing pushed) until the first stereo push.
// ---------------------------------------------------------------------------
static vc_stereo_eye_matrices_t gStereoEyes = {0};
static os_unfair_lock          gStereoEyesLock = OS_UNFAIR_LOCK_INIT;

void vc_set_stereo_eye_matrices(const vc_stereo_eye_matrices_t *eyes) {
    if (eyes == NULL) return;

    os_unfair_lock_lock(&gStereoEyesLock);
    gStereoEyes = *eyes;
    os_unfair_lock_unlock(&gStereoEyesLock);

    // Throttled (~1/s): per-eye translation + first projection row, so the eye
    // separation can be checked -- expect ~0.06 m (real IPD), NOT 1.0 (the old
    // synthetic +/-0.5 m offset the render path still uses until it consumes this).
    if (!eyes->valid) return;
    static double lastLog = 0.0;
    double nowT = CFAbsoluteTimeGetCurrent();
    if (nowT - lastLog < 1.0) return;
    lastLog = nowT;

    simd_float4 tL = eyes->view[0].columns[3];
    simd_float4 tR = eyes->view[1].columns[3];
    float dx = tL.x - tR.x, dy = tL.y - tR.y, dz = tL.z - tR.z;
    float sep = sqrtf(dx*dx + dy*dy + dz*dz);
    // proj.row0 = first ROW of the column-major matrix = columns[c].x, matching
    // the Phase 1 log format so the two can be compared directly.
    NSLog(@"[vc-eyes] L view.t=(%.4f, %.4f, %.4f) proj.row0=(%.4f, %.4f, %.4f, %.4f)",
          tL.x, tL.y, tL.z,
          eyes->projection[0].columns[0].x, eyes->projection[0].columns[1].x,
          eyes->projection[0].columns[2].x, eyes->projection[0].columns[3].x);
    NSLog(@"[vc-eyes] R view.t=(%.4f, %.4f, %.4f) proj.row0=(%.4f, %.4f, %.4f, %.4f)",
          tR.x, tR.y, tR.z,
          eyes->projection[1].columns[0].x, eyes->projection[1].columns[1].x,
          eyes->projection[1].columns[2].x, eyes->projection[1].columns[3].x);
    NSLog(@"[vc-eyes] eye separation = %.4f m (expect ~0.06, not 1.0)", sep);
}

bool vc_get_stereo_eye_matrices(vc_stereo_eye_matrices_t *out) {
    if (out == NULL) return false;
    os_unfair_lock_lock(&gStereoEyesLock);
    bool valid = gStereoEyes.valid != 0;
    if (valid) *out = gStereoEyes;
    os_unfair_lock_unlock(&gStereoEyesLock);
    return valid;
}
