//
//  VCDiagnostics.h
//  AvpViceCity
//
//  Swift-facing slice of the stutter diagnostics recorder (reVC src/skel/visionos/vc_diag.h).
//  Present only in the Xcode configuration "Diagnostics" (VC_DIAGNOSTICS=1 for C/C++ and
//  VC_DIAGNOSTICS in SWIFT_ACTIVE_COMPILATION_CONDITIONS); in Release this header is empty,
//  so no declaration, call or string of the recorder reaches the Release binary.
//

#ifndef VCDiagnostics_h
#define VCDiagnostics_h

#if VC_DIAGNOSTICS

#ifdef __cplusplus
extern "C" {
#endif

/// Event kinds the host reports. Mirror of the matching entries in vc_diag.h -- keep in sync.
#define VC_DIAG_EV_LAYER_PAUSED  4   ///< LayerRenderer paused (headset taken off, Digital Crown)
#define VC_DIAG_EV_LAYER_RESUMED 5   ///< LayerRenderer running again

/// Record an event line (any thread; lock-free ring, written by the background writer).
/// No-op until the recorder is on (launcher toggle "Record stutter diagnostics").
void vc_diag_event(int kind, int a, int b, int c);

#ifdef __cplusplus
}
#endif

#endif /* VC_DIAGNOSTICS */
#endif /* VCDiagnostics_h */
