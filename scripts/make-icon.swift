// Builds PullTube's 1024px app icon from Design/icon-source.png (a red music
// folder): lifts the white note off the folder, repaints the folder where it
// was, and puts the note back 50% larger.
// Usage: swift scripts/make-icon.swift <source.png> <output.png> [scale=1.5]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let srcImage = NSImage(contentsOfFile: args[1])?
        .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <source.png> <output.png> [scale]\n".utf8)); exit(1)
}
let noteScale = args.count > 3 ? CGFloat(Double(args[3]) ?? 1.5) : 1.5

let W = 1024, H = 1024
let space = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space, bitmapInfo: info)!
ctx.interpolationQuality = .high
ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: W, height: H))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)   // row 0 = top

// 1. Find the note: the only near-white pixels on the red folder front.
//    Coverage comes from the green/blue channels, which are ~0 on the red.
func coverage(_ x: Int, _ y: Int) -> Double {
    let i = (y * W + x) * 4
    let m = Double(min(px[i + 1], px[i + 2]))
    return max(0, min(1, (m - 70) / 110))
}
var minX = W, maxX = 0, minY = H, maxY = 0
for y in 400..<800 { for x in 280..<720 where coverage(x, y) > 0.08 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
guard minX < maxX else { FileHandle.standardError.write(Data("note not found\n".utf8)); exit(1) }
// Grow the box so the note's soft shadow is cleaned up too.
let pad = 14
let x0 = minX - pad, x1 = maxX + pad, y0 = minY - pad, y1 = maxY + pad
let bw = x1 - x0 + 1, bh = y1 - y0 + 1

// 2. Lift the note into its own layer (un-mixing the red behind soft edges)
//    and repaint the folder underneath from the red on either side.
var note = [UInt8](repeating: 0, count: bw * bh * 4)
var rng = SystemRandomNumberGenerator()
for y in y0...y1 {
    let li = (y * W + (x0 - 1)) * 4, ri = (y * W + (x1 + 1)) * 4
    let left = (0..<3).map { Double(px[li + $0]) }, right = (0..<3).map { Double(px[ri + $0]) }
    for x in x0...x1 {
        let i = (y * W + x) * 4
        let t = Double(x - x0 + 1) / Double(bw + 1)
        let bg = (0..<3).map { left[$0] + (right[$0] - left[$0]) * t }
        let a = coverage(x, y)
        if a > 0 {
            let ni = ((y - y0) * bw + (x - x0)) * 4
            for c in 0..<3 {
                let unmixed = (Double(px[i + c]) - (1 - a) * bg[c]) / a
                note[ni + c] = UInt8(max(0, min(255, unmixed)) * a)      // premultiplied
            }
            note[ni + 3] = UInt8(a * 255)
        }
        // A touch of grain so the patch matches the folder's paper texture.
        let grain = Double(Int.random(in: -2...2, using: &rng))
        for c in 0..<3 { px[i + c] = UInt8(max(0, min(255, bg[c] + grain))) }
        px[i + 3] = 255
    }
}

// 3. Put the note back, larger, centred where it was.
let noteCtx = note.withUnsafeMutableBytes { buf in
    CGContext(data: buf.baseAddress, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
              space: space, bitmapInfo: info)!.makeImage()!
}
let cx = CGFloat(x0 + x1 + 1) / 2, cyTop = CGFloat(y0 + y1 + 1) / 2
let dw = CGFloat(bw) * noteScale, dh = CGFloat(bh) * noteScale
let dest = CGRect(x: cx - dw / 2, y: CGFloat(H) - cyTop - dh / 2, width: dw, height: dh)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 6,
              color: CGColor(colorSpace: space, components: [0.35, 0, 0, 0.55])!)
ctx.draw(noteCtx, in: dest)
ctx.restoreGState()

// 4. Crop to the folder (ignoring the faint outer shadow) and scale it up to
//    fill the whole canvas, keeping its proportions. Outside stays transparent.
var cMinX = W, cMaxX = 0, cMinY = H, cMaxY = 0
for y in 0..<H { for x in 0..<W where px[(y * W + x) * 4 + 3] > 40 {
    cMinX = min(cMinX, x); cMaxX = max(cMaxX, x); cMinY = min(cMinY, y); cMaxY = max(cMaxY, y)
} }
let composed = ctx.makeImage()!
let content = CGRect(x: cMinX, y: cMinY, width: cMaxX - cMinX + 1, height: cMaxY - cMinY + 1)
let fit = min(CGFloat(W) / content.width, CGFloat(H) / content.height)
let outCtx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space, bitmapInfo: info)!
outCtx.interpolationQuality = .high
// Place the whole image so that `content` (top-left coordinates) lands centred at full size.
let scaledW = CGFloat(W) * fit, scaledH = CGFloat(H) * fit
let offsetX = (CGFloat(W) - content.width * fit) / 2 - content.minX * fit
let offsetTop = (CGFloat(H) - content.height * fit) / 2 - content.minY * fit
outCtx.draw(composed, in: CGRect(x: offsetX, y: CGFloat(H) - offsetTop - scaledH, width: scaledW, height: scaledH))

let rep = NSBitmapImageRep(cgImage: outCtx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("folder \(Int(content.width))×\(Int(content.height)) of 1024 → enlarged ×\(String(format: "%.2f", fit))")
print("note box \(maxX - minX + 1)×\(maxY - minY + 1) at (\(minX), \(minY)) → scaled ×\(noteScale)")
