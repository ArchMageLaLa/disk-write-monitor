import AppKit
import CoreGraphics

// 生成 1024×1024 应用图标：深色圆角底 + 写入曲线

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let outer = CGRect(x: 32, y: 32, width: 960, height: 960)
ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 214, cornerHeight: 214, transform: nil))
ctx.clip()

let top = NSColor(srgbRed: 0.086, green: 0.125, blue: 0.169, alpha: 1).cgColor
let bottom = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.063, alpha: 1).cgColor
let bg = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 992), end: CGPoint(x: 0, y: 32), options: [])

let accent = NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 1).cgColor

// 曲线数据（从左到右）
let baseline: CGFloat = 380
let points: [CGPoint] = [
    CGPoint(x: 140, y: baseline),
    CGPoint(x: 250, y: baseline),
    CGPoint(x: 340, y: 735),
    CGPoint(x: 420, y: 640),
    CGPoint(x: 480, y: baseline),
    CGPoint(x: 560, y: baseline),
    CGPoint(x: 650, y: 690),
    CGPoint(x: 730, y: 610),
    CGPoint(x: 790, y: baseline),
    CGPoint(x: 850, y: baseline),
]

// 面积
let area = CGMutablePath()
area.move(to: CGPoint(x: points[0].x, y: baseline))
for p in points { area.addLine(to: p) }
area.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
area.closeSubpath()
ctx.saveGState()
ctx.addPath(area)
ctx.clip()
let fill = CGGradient(
    colorsSpace: space,
    colors: [NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 0.42).cgColor,
             NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 0.02).cgColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: 780), end: CGPoint(x: 0, y: baseline), options: [])
ctx.restoreGState()

// 曲线
ctx.setStrokeColor(accent)
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.beginPath()
ctx.move(to: points[0])
for p in points.dropFirst() { ctx.addLine(to: p) }
ctx.strokePath()

// 末端光点
let end = points[points.count - 1]
ctx.setFillColor(NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 0.22).cgColor)
ctx.fillEllipse(in: CGRect(x: end.x - 46, y: end.y - 46, width: 92, height: 92))
ctx.setFillColor(accent)
ctx.fillEllipse(in: CGRect(x: end.x - 24, y: end.y - 24, width: 48, height: 48))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
