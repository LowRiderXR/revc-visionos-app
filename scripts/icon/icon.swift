// Renders the three layers of the visionOS app icon (1024x1024 each, full square -- the
// system applies the round mask) plus composite previews (square, round, 128 px).
// Pure CoreGraphics, no assets: sunset over the sea, palm silhouettes.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S = 1024
let F = CGFloat(S)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func makeContext(_ size: Int = S) -> CGContext {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r/255, g/255, b/255, a])!
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locs)!
}
func save(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
func save(_ ctx: CGContext, _ name: String) { save(ctx.makeImage()!, name) }

// Layout (CoreGraphics origin bottom-left). Horizon at 42 % height, sun centred.
let horizonY = F * 0.42
let sunCX = F * 0.5, sunCY = horizonY + F * 0.12, sunR = F * 0.27
let skyGradient = gradient([rgb(28, 10, 60), rgb(92, 24, 110), rgb(214, 64, 140), rgb(255, 140, 90)], [0, 0.35, 0.72, 1.0])
func drawSky(_ c: CGContext) {
    c.drawLinearGradient(skyGradient, start: CGPoint(x: 0, y: F), end: CGPoint(x: 0, y: horizonY - 40),
                         options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
}

// ---------- BACK: sky, stars, sun ----------
let back = makeContext()
drawSky(back)
srand48(7)
back.setFillColor(rgb(255, 230, 240, 0.55))
for _ in 0..<60 {
    let x = CGFloat(drand48()) * F
    let y = horizonY + F * 0.30 + CGFloat(drand48()) * (F - horizonY - F * 0.30)
    let r = CGFloat(1.2 + drand48() * 2.2)
    back.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2*r, height: 2*r))
}
back.drawRadialGradient(gradient([rgb(255, 200, 120, 0.55), rgb(255, 120, 150, 0.0)], [0, 1]),
                        startCenter: CGPoint(x: sunCX, y: sunCY), startRadius: sunR * 0.8,
                        endCenter: CGPoint(x: sunCX, y: sunCY), endRadius: sunR * 1.9, options: [])
back.saveGState()
back.addEllipse(in: CGRect(x: sunCX - sunR, y: sunCY - sunR, width: 2*sunR, height: 2*sunR))
back.clip()
back.drawLinearGradient(gradient([rgb(255, 236, 150), rgb(255, 170, 70), rgb(255, 90, 120)], [0, 0.55, 1]),
                        start: CGPoint(x: 0, y: sunCY + sunR), end: CGPoint(x: 0, y: sunCY - sunR), options: [])
// 80s cuts in the lower half: sky shows through (the layer stays opaque)
var stripes: [CGRect] = []
var y = sunCY - sunR * 0.08
var gap: CGFloat = 9
while y > sunCY - sunR {
    let h = gap * 0.9
    stripes.append(CGRect(x: sunCX - sunR, y: y - h, width: 2*sunR, height: h))
    y -= gap * 2.6
    gap += 8
}
back.clip(to: stripes)
drawSky(back)
back.restoreGState()
save(back, "Back.png")

// ---------- MIDDLE: sea, horizon glow, soft reflection ----------
let mid = makeContext()
mid.saveGState()
mid.clip(to: CGRect(x: 0, y: 0, width: F, height: horizonY))
mid.drawLinearGradient(gradient([rgb(70, 230, 220), rgb(20, 150, 170), rgb(8, 60, 110), rgb(10, 25, 70)], [0, 0.25, 0.7, 1.0]),
                       start: CGPoint(x: 0, y: horizonY), end: CGPoint(x: 0, y: 0), options: [])
// reflection: rounded streaks, each with a horizontal sun-coloured gradient that fades at the
// ends, overall fading with distance from the horizon
var ry = horizonY - 10
var rw = sunR * 1.5
var rh: CGFloat = 7
var alpha: CGFloat = 0.85
while ry > horizonY * 0.22 {
    let rect = CGRect(x: sunCX - rw/2, y: ry - rh, width: rw, height: rh)
    mid.saveGState()
    mid.addPath(CGPath(roundedRect: rect, cornerWidth: rh/2, cornerHeight: rh/2, transform: nil))
    mid.clip()
    mid.drawLinearGradient(gradient([rgb(255, 120, 150, 0), rgb(255, 170, 90, alpha), rgb(255, 225, 150, alpha), rgb(255, 170, 90, alpha), rgb(255, 120, 150, 0)],
                                    [0, 0.18, 0.5, 0.82, 1]),
                           start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
    mid.restoreGState()
    ry -= rh * 2.4
    rw *= 0.88
    rh *= 1.22
    alpha *= 0.86
}
mid.drawLinearGradient(gradient([rgb(255, 220, 170, 0.9), rgb(255, 220, 170, 0.0)], [0, 1]),
                       start: CGPoint(x: 0, y: horizonY), end: CGPoint(x: 0, y: horizonY - 60), options: [])
mid.restoreGState()
save(mid, "Middle.png")

// ---------- FRONT: dune + palm silhouettes ----------
let front = makeContext()
let ink = rgb(22, 8, 40)
front.setFillColor(ink); front.setStrokeColor(ink)
let dune = CGMutablePath()
dune.move(to: CGPoint(x: 0, y: 0))
dune.addLine(to: CGPoint(x: 0, y: 150))
dune.addCurve(to: CGPoint(x: F, y: 110), control1: CGPoint(x: 330, y: 230), control2: CGPoint(x: 700, y: 40))
dune.addLine(to: CGPoint(x: F, y: 0))
dune.closeSubpath()
front.addPath(dune); front.fillPath()

/// Smooth tapered leaf from `top`, drooping along `angle`, with a few clean notches cut
/// into its underside (blend mode .clear -> transparent on this layer).
func leaf(_ c: CGContext, top: CGPoint, angle a: CGFloat, length len: CGFloat, width half: CGFloat, droop: CGFloat) {
    let dir = CGPoint(x: cos(a), y: sin(a))
    let nx = -dir.y, ny = dir.x
    let end = CGPoint(x: top.x + dir.x * len, y: top.y + dir.y * len - len * droop)
    let ctrl = CGPoint(x: top.x + dir.x * len * 0.55, y: top.y + dir.y * len * 0.55 + len * 0.22)
    func on(_ t: CGFloat) -> CGPoint {   // point on the centre curve
        CGPoint(x: (1-t)*(1-t)*top.x + 2*(1-t)*t*ctrl.x + t*t*end.x,
                y: (1-t)*(1-t)*top.y + 2*(1-t)*t*ctrl.y + t*t*end.y)
    }
    let shape = CGMutablePath()
    shape.move(to: CGPoint(x: top.x + nx * half * 0.5, y: top.y + ny * half * 0.5))
    shape.addQuadCurve(to: end, control: CGPoint(x: ctrl.x + nx * half * 1.1, y: ctrl.y + ny * half * 1.1))
    shape.addQuadCurve(to: CGPoint(x: top.x - nx * half * 0.5, y: top.y - ny * half * 0.5), control: CGPoint(x: ctrl.x - nx * half * 1.1, y: ctrl.y - ny * half * 1.1))
    shape.closeSubpath()
    c.addPath(shape); c.fillPath()
    // three notches on the lower edge, as narrow wedges pointing at the centre line
    c.saveGState()
    c.setBlendMode(.clear)
    for t in [CGFloat(0.48), 0.68] {
        let p = on(t)
        let w = half * 1.1 * (1 - t * 0.6)              // local half width
        let side = (ny < 0) ? 1.0 : -1.0                // the edge that faces down
        let edge = CGPoint(x: p.x + nx * w * CGFloat(side), y: p.y + ny * w * CGFloat(side))
        let wedge = CGMutablePath()
        let along = CGPoint(x: dir.x * w * 0.9, y: dir.y * w * 0.9)
        wedge.move(to: CGPoint(x: edge.x - along.x * 0.5, y: edge.y - along.y * 0.5))
        wedge.addLine(to: CGPoint(x: p.x + nx * w * 0.25 * CGFloat(side), y: p.y + ny * w * 0.25 * CGFloat(side)))
        wedge.addLine(to: CGPoint(x: edge.x + along.x * 0.5, y: edge.y + along.y * 0.5))
        wedge.closeSubpath()
        c.addPath(wedge); c.fillPath()
    }
    c.restoreGState()
}

func palm(_ c: CGContext, base: CGPoint, height: CGFloat, lean: CGFloat, scale: CGFloat) {
    let top = CGPoint(x: base.x + lean, y: base.y + height)
    let c1 = CGPoint(x: base.x + lean * 0.15, y: base.y + height * 0.45)
    let c2 = CGPoint(x: base.x + lean * 0.75, y: base.y + height * 0.8)
    let trunk = CGMutablePath()
    let w0 = 34 * scale, w1 = 15 * scale
    trunk.move(to: CGPoint(x: base.x - w0/2, y: base.y))
    trunk.addCurve(to: CGPoint(x: top.x - w1/2, y: top.y), control1: CGPoint(x: c1.x - w0/2, y: c1.y), control2: CGPoint(x: c2.x - w1/2, y: c2.y))
    trunk.addLine(to: CGPoint(x: top.x + w1/2, y: top.y))
    trunk.addCurve(to: CGPoint(x: base.x + w0/2, y: base.y), control1: CGPoint(x: c2.x + w1/2, y: c2.y), control2: CGPoint(x: c1.x + w0/2, y: c1.y))
    trunk.closeSubpath()
    c.setFillColor(ink)
    c.addPath(trunk); c.fillPath()
    // crown: leaves fanning out, longer ones to the sides, shorter upward
    let spec: [(angle: CGFloat, len: CGFloat, droop: CGFloat)] = [
        (-0.25, 0.95, 0.55), (0.30, 1.0, 0.45), (0.80, 0.85, 0.35), (1.30, 0.70, 0.25),
        (1.85, 0.70, 0.25), (2.35, 0.85, 0.35), (2.85, 1.0, 0.45), (3.40, 0.95, 0.55)
    ]
    for s in spec {
        leaf(c, top: top, angle: s.angle, length: 300 * scale * s.len, width: 30 * scale, droop: s.droop)
    }
    for d in [CGPoint(x: -16, y: -14), CGPoint(x: 12, y: -18), CGPoint(x: -1, y: 2)] {
        let r = 15 * scale
        c.fillEllipse(in: CGRect(x: top.x + d.x * scale - r, y: top.y + d.y * scale - r, width: 2*r, height: 2*r))
    }
}
palm(front, base: CGPoint(x: 150, y: 125), height: 470, lean: 60, scale: 0.9)
palm(front, base: CGPoint(x: 905, y: 100), height: 300, lean: -45, scale: 0.6)
save(front, "Front.png")

// ---------- previews ----------
func load(_ n: String) -> CGImage {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(n)
    return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
}
func composite(_ size: Int, round: Bool) -> CGImage {
    let c = makeContext(size)
    if round { c.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size)); c.clip() }
    for n in ["Back.png", "Middle.png", "Front.png"] { c.draw(load(n), in: CGRect(x: 0, y: 0, width: size, height: size)) }
    return c.makeImage()!
}
save(composite(S, round: false), "Preview-square.png")
save(composite(S, round: true), "Preview-round.png")
save(composite(128, round: true), "Preview-128.png")
// 128 px shown enlarged 4x (nearest) next to the real-size one, for inspection
let sheet = makeContext(640)
sheet.setFillColor(rgb(40, 40, 44)); sheet.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
sheet.interpolationQuality = .none
sheet.draw(load("Preview-128.png"), in: CGRect(x: 64, y: 64, width: 512, height: 512))
sheet.draw(load("Preview-128.png"), in: CGRect(x: 8, y: 8, width: 128, height: 128))
save(sheet, "Preview-128-sheet.png")
print("written to \(outDir)")
