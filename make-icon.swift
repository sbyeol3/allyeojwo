// 🔔 이모지로 앱 아이콘 세트를 만든다. 사용: swift make-icon.swift <출력 .iconset 폴더>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = base * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let text = NSAttributedString(string: "🔔", attributes: [.font: NSFont.systemFont(ofSize: size * 0.8)])
    let textSize = text.size()
    text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
    NSGraphicsContext.restoreGraphicsState()

    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
  }
}
