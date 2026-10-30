// 生成 README 顶部 Banner：swift macos/icon/make-banner.swift docs/banner.png
import AppKit
let W = 1600, H = 520
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 0, y: 0, width: W, height: H)
NSGradient(colors: [NSColor(red: 0.16, green: 0.34, blue: 0.93, alpha: 1), NSColor(red: 0.42, green: 0.58, blue: 1, alpha: 1)])!.draw(in: r, angle: 20)
let icon = NSRect(x: 130, y: 160, width: 200, height: 200)
NSColor.white.withAlphaComponent(0.18).setFill(); NSBezierPath(roundedRect: icon, xRadius: 46, yRadius: 46).fill()
let cfg = NSImage.SymbolConfiguration(pointSize: 96, weight: .medium).applying(.init(paletteColors: [.white]))
if let s = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    s.draw(in: NSRect(x: icon.midX - s.size.width / 2, y: icon.midY - s.size.height / 2, width: s.size.width, height: s.size.height))
}
func text(_ t: String, _ size: CGFloat, _ w: NSFont.Weight, _ y: CGFloat, _ a: CGFloat = 1) {
    (t as NSString).draw(at: NSPoint(x: 400, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: w),
                                                                    .foregroundColor: NSColor.white.withAlphaComponent(a)])
}
text("面搭子 InterviewMate", 84, .bold, 270)
text("面试官的 AI 搭子：读简历出题 · 实时转写追问 · 面后复盘评价", 36, .medium, 200, 0.92)
text("macOS · SwiftUI · Claude", 26, .regular, 150, 0.75)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
