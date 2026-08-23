//
//  ShaderTypes.h
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

#ifndef __METAL_VERSION__
// Expose the plain-C renderer boundary to Swift via this bridging header.
// Guarded so it never enters Metal shader compilation.
#include "VCPlatform.h"
#endif

#endif /* ShaderTypes_h */

