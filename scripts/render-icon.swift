import AppKit

// Рендер icon.svg в набор PNG для .icns.
// NSImage на macOS умеет SVG сам, поэтому сторонние конвертеры не нужны.

let arguments = CommandLine.arguments
guard arguments.count >= 3, let source = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("не удалось прочитать SVG\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[2])

/// Доля холста, которую занимает рисунок.
/// Иконка-плашка (скруглённый квадрат) должна занимать 824 из 1024, иначе она
/// выглядит крупнее соседей в Dock. Иконке свободной формы, у которой поля уже
/// заложены в сам рисунок, второй отступ не нужен — она идёт на полный холст.
let bodyRatio: CGFloat = arguments.count > 3 ? CGFloat(Double(arguments[3]) ?? 1.0) : 1.0

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let side = CGFloat(variant.pixels)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: variant.pixels, pixelsHigh: variant.pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let body = side * bodyRatio
    let inset = (side - body) / 2
    source.draw(in: NSRect(x: inset, y: inset, width: body, height: body),
                from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
