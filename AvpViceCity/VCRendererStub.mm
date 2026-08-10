//
//  VCRendererStub.mm
//  AvpViceCity
//
//  Temporary stub implementation of the VCPlatform boundary. It bridges the
//  opaque Metal handles back to their ARC types and logs the device once on
//  init; it performs no rendering. The real implementation will be provided by
//  the C++ game engine linked in as a static library later.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "VCPlatform.h"

bool vc_renderer_init(void *mtl_device) {
    if (mtl_device == NULL) {
        NSLog(@"[VCRenderer] init failed: null Metal device");
        return false;
    }

    // Bridge the opaque handle back to its ARC type without transferring
    // ownership; the Swift host retains the device for its lifetime.
    id<MTLDevice> device = (__bridge id<MTLDevice>)mtl_device;
    NSLog(@"[VCRenderer] init with device %p (name: %@)", (__bridge void *)device, device.name);
    // NSLog(@"[VCRenderer] init with device %p (name: %@)", (void *)device, device.name);
    return true;
}

void vc_renderer_render(const vc_frame_t *frame) {
    if (frame == NULL) {
        return;
    }

    // Bridge the opaque per-frame Metal handles back to their ARC types. The
    // future C++ renderer will consume these; the stub does no work and logs
    // nothing per frame to keep the frame path quiet.
    id<MTLTexture> colorTexture = (__bridge id<MTLTexture>)frame->color_texture;
    id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)frame->depth_texture;
    id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)frame->command_buffer;

    (void)colorTexture;
    (void)depthTexture;
    (void)commandBuffer;
}

void vc_renderer_shutdown(void) {
    NSLog(@"[VCRenderer] shutdown");
}
