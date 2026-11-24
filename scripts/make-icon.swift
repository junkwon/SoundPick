// Draws SoundPick's 1024px app icon from scratch: a red rounded square with
// a white guitar pick ("pick") holding a pair of beamed notes ("sound").
// Everything is drawn here with Core Graphics; no outside artwork is used.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8)); exit(1)
}
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

// 1. The plate: macOS icon proportions (824pt square on a 1024pt canvas).
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
ctx.addPath(platePath)
ctx.setFillColor(color(0xC8141B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0xF0413A), color(0xB50D15)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.minY), options: [])
ctx.restoreGState()

// 2. The pick: a soft triangle, point down. Each side is a curve from the
//    middle of one edge to the middle of the next, pulled towards the corner.
let cx: CGFloat = 512, cy: CGFloat = 500
let a = CGPoint(x: cx - 345, y: cy + 300), b = CGPoint(x: cx + 345, y: cy + 300), c = CGPoint(x: cx, y: cy - 440)
func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
let pick = CGMutablePath()
pick.move(to: mid(a, b))
pick.addQuadCurve(to: mid(b, c), control: b)
pick.addQuadCurve(to: mid(c, a), control: c)
pick.addQuadCurve(to: mid(a, b), control: a)
pick.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x5A0006, 0.45))
ctx.addPath(pick)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// 3. The notes, in the plate's red.
ctx.setFillColor(color(0xC8141B))
let left = CGPoint(x: cx - 92, y: cy - 48), right = CGPoint(x: cx + 82, y: cy - 14)
let headW: CGFloat = 112, headH: CGFloat = 84, stemW: CGFloat = 24, stemH: CGFloat = 232, beamH: CGFloat = 50
for head in [left, right] {
    ctx.saveGState()
    ctx.translateBy(x: head.x, y: head.y)
    ctx.rotate(by: 0.36)
    ctx.fillEllipse(in: CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH))
    ctx.restoreGState()
    // Stem up the right-hand side of the head.
    // (A touch short of the beam's top edge, which slopes across the stem.)
    ctx.fill(CGRect(x: head.x + headW / 2 - stemW - 3, y: head.y + 8, width: stemW, height: stemH - 8))
}
// Beam across the two stem tops.
let lx = left.x + headW / 2 - stemW - 3, rx = right.x + headW / 2 - 3
let beam = CGMutablePath()
beam.move(to: CGPoint(x: lx, y: left.y + 8 + stemH))
beam.addLine(to: CGPoint(x: rx, y: right.y + 8 + stemH))
beam.addLine(to: CGPoint(x: rx, y: right.y + 8 + stemH - beamH))
beam.addLine(to: CGPoint(x: lx, y: left.y + 8 + stemH - beamH))
beam.closeSubpath()
ctx.addPath(beam)
ctx.fillPath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon drawn")
