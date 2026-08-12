//
//  VCRendererStub.mm
//  AvpViceCity
//
//  Minimal but real Metal renderer behind the VCPlatform boundary. It draws a
//  single, world-anchored triangle once per eye into the colour/depth textures
//  the Swift host hands over each frame. It never creates or commits a command
//  buffer and never presents — the Swift host still owns submission. The
//  existing throttled diagnostics are kept.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "VCPlatform.h"

// Must match `VCTriangleUniforms` in VCTriangle.metal (column-major float4x4).
typedef struct {
    simd_float4x4 view;
    simd_float4x4 projection;
    uint32_t slice;
} VCTriangleUniforms;

// Cached GPU resources — built once, never rebuilt per frame.
static id<MTLDevice> gDevice = nil;
static id<MTLRenderPipelineState> gPipeline = nil;
static id<MTLDepthStencilState> gDepthState = nil;
static id<MTLBuffer> gVertexBuffer = nil;
static id<MTLFunction> gVertexFunction = nil;
static id<MTLFunction> gFragmentFunction = nil;
static bool gPipelineFailed = false;

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
    desc.maxVertexAmplificationCount = 1; // no amplification in this baseline
    // Required because the vertex shader writes [[render_target_array_index]]
    // for layered (per-eye) rendering: Metal needs the primitive topology.
    desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
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

void vc_renderer_render(const vc_frame_t *frame) {
    if (frame == NULL) {
        return;
    }

    // Bridge the opaque per-frame Metal handles back to their ARC types.
    id<MTLTexture> colorTexture = (__bridge id<MTLTexture>)frame->color_texture;
    id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)frame->depth_texture;
    id<MTLRasterizationRateMap> rateMap = (__bridge id<MTLRasterizationRateMap>)frame->rate_map;
    id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)frame->command_buffer;

    // --- Encode the world-anchored triangle, once per eye, every frame ------
    if (commandBuffer != nil && colorTexture != nil && depthTexture != nil &&
        vc_build_pipeline_if_needed(colorTexture, depthTexture)) {

        MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        // loadAction .load: keep whatever the Swift renderer already drew.
        passDescriptor.colorAttachments[0].texture = colorTexture;
        passDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
        passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDescriptor.depthAttachment.texture = depthTexture;
        passDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
        passDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
        if (rateMap != nil) {
            passDescriptor.rasterizationRateMap = rateMap;
        }
        // Layered render target: each eye's draw routes to its own slice via
        // the shader's [[render_target_array_index]] output.
        passDescriptor.renderTargetArrayLength = frame->eye_count;

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
        encoder.label = @"vc.triangle";
        [encoder setRenderPipelineState:gPipeline];
        [encoder setDepthStencilState:gDepthState];
        [encoder setCullMode:MTLCullModeNone];

        // With a rasterization rate map the viewport is screen space (the map
        // compresses to the physical texture); otherwise it is the full texture.
        MTLViewport viewport;
        if (rateMap != nil) {
            MTLSize screenSize = rateMap.screenSize;
            viewport = (MTLViewport){0.0, 0.0, (double)screenSize.width, (double)screenSize.height, 0.0, 1.0};
        } else {
            viewport = (MTLViewport){0.0, 0.0, (double)colorTexture.width, (double)colorTexture.height, 0.0, 1.0};
        }
        [encoder setViewport:viewport];
        [encoder setVertexBuffer:gVertexBuffer offset:0 atIndex:0];

        // One draw call per eye (no vertex amplification in this baseline).
        const uint32_t eyeCount = frame->eye_count < 2 ? frame->eye_count : 2;
        for (uint32_t i = 0; i < eyeCount; i++) {
            VCTriangleUniforms uniforms;
            uniforms.view = frame->eyes[i].view;
            uniforms.projection = frame->eyes[i].projection;
            uniforms.slice = frame->eyes[i].slice;
            [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }

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
