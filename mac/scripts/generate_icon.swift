import AppKit

func createIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    // Squircle path
    let inset = s * 0.05
    let corner = s * 0.22
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    // Cosmic Galaxy Gradient (Samsung Blue & Purple)
    let bg = NSGradient(
        colors: [
            NSColor(red: 0.01, green: 0.50, blue: 0.99, alpha: 1.0), // Galaxy Blue
            NSColor(red: 0.12, green: 0.15, blue: 0.55, alpha: 1.0),
            NSColor(red: 0.45, green: 0.15, blue: 0.75, alpha: 1.0)  // Nebula Purple
        ],
        atLocations: [0.0, 0.5, 1.0],
        colorSpace: .sRGB
    )!
    bg.draw(in: path, angle: -45)

    // Subtle frosted glass border
    NSColor(white: 1.0, alpha: 0.25).setStroke()
    path.lineWidth = max(1, s * 0.015)
    path.stroke()

    // Center glyph: Continuity arrows
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symSize = s * 0.55
        let symRect = CGRect(x: (s - symSize) / 2, y: (s - symSize) / 2, width: symSize, height: symSize)
        symbol.draw(in: symRect)
    }

    img.unlockFocus()
    return img
}

let fm = FileManager.default
let iconsetDir = "AppIcon.iconset"
try? fm.removeItem(atPath: iconsetDir)
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (dim, name) in sizes {
    let img = createIcon(size: dim)
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let path = "\(iconsetDir)/\(name)"
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

print("Iconset created successfully")
