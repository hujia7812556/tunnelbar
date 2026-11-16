#!/usr/bin/env swift
import AppKit

/// 以连续圆角和几何图形生成应用图标，避免缩放时出现不规则透明边缘。
func generateIcon(at destination: URL) throws {
    let size = 1024
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let tile = continuousSquare(in: CGRect(x: 100, y: 100, width: 824, height: 824))

    // 阴影只提供轻微层次，主体边缘始终由精确路径决定。
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -4), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.16).cgColor)
    context.addPath(tile)
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let colors = [NSColor(srgbRed: 0.025, green: 0.19, blue: 0.78, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.015, green: 0.48, blue: 0.81, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.05, green: 0.76, blue: 0.75, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: colors as CFArray, locations: [0, 0.58, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 100),
                                   end: CGPoint(x: 780, y: 924),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    context.setLineWidth(2)
    context.strokePath()

    // 拱形入口和两条反向箭头在小尺寸下保留清晰的正负形。
    let portal = CGMutablePath()
    portal.move(to: CGPoint(x: 294, y: 294))
    portal.addLine(to: CGPoint(x: 294, y: 514))
    portal.addArc(center: CGPoint(x: 512, y: 514), radius: 218,
                  startAngle: .pi, endAngle: 0, clockwise: true)
    portal.addLine(to: CGPoint(x: 730, y: 294))
    portal.closeSubpath()
    let foreground = NSColor(srgbRed: 0.96, green: 0.985, blue: 1, alpha: 1).cgColor
    context.addPath(portal)
    context.setStrokeColor(foreground)
    context.setLineWidth(28)
    context.setLineJoin(.miter)
    context.strokePath()
    context.setFillColor(foreground)
    fillPolygon([(378, 552), (584, 552), (584, 518), (650, 565),
                 (584, 612), (584, 578), (378, 578)], in: context)
    fillPolygon([(648, 443), (440, 443), (440, 477), (374, 430),
                 (440, 383), (440, 417), (648, 417)], in: context)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: destination, options: .atomic)
}

/// 通过超椭圆生成连续圆角，四边与拐角保持平滑衔接。
func continuousSquare(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    for step in 0..<512 {
        let angle = Double(step) * 2 * .pi / 512
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = copysign(pow(abs(cosine), 2 / 4.5), cosine)
        let y = copysign(pow(abs(sine), 2 / 4.5), sine)
        let point = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// 填充封闭箭头，保持两条箭头使用相同的笔画和箭头比例。
func fillPolygon(_ points: [(CGFloat, CGFloat)], in context: CGContext) {
    context.beginPath()
    for (index, point) in points.enumerated() {
        let position = CGPoint(x: point.0, y: point.1)
        if index == 0 { context.move(to: position) } else { context.addLine(to: position) }
    }
    context.closePath()
    context.fillPath()
}

let destination = CommandLine.arguments.dropFirst().first ?? "TunnelBar/Resources/AppIcon.png"
try generateIcon(at: URL(fileURLWithPath: destination))
