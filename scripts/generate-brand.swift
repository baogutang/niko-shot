// Reproduces the original NIKO monogram and application icons using system drawing APIs.
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let gold = NSColor(srgbRed: 0.91, green: 0.64, blue: 0.20, alpha: 1)

func image(size: Int, tile: Bool, dark: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.coderInvalidValue) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.cgContext.setShouldAntialias(true)
    if tile {
        let shape = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202)
        NSColor(srgbRed: 0.98, green: 0.96, blue: 0.91, alpha: 1).setFill(); shape.fill()
        NSColor(srgbRed: 0.84, green: 0.81, blue: 0.73, alpha: 0.65).setStroke()
        shape.lineWidth = 4; shape.stroke()
    }
    // Four brackets make the initial a capture tool; the diagonal keeps N legible at 16 px.
    let frame = NSBezierPath(); frame.lineWidth = 46; frame.lineCapStyle = .round; frame.lineJoinStyle = .round
    for (x,y,dx,dy) in [(234.0,234.0,1.0,1.0),(790.0,234.0,-1.0,1.0),(234.0,790.0,1.0,-1.0),(790.0,790.0,-1.0,-1.0)] {
        frame.move(to: NSPoint(x:x+108*dx,y:y)); frame.line(to:NSPoint(x:x,y:y)); frame.line(to:NSPoint(x:x,y:y+108*dy))
    }
    gold.setStroke(); frame.stroke()
    let n = NSBezierPath()
    n.move(to: NSPoint(x:330,y:326)); n.line(to:NSPoint(x:330,y:698))
    n.line(to:NSPoint(x:418,y:698)); n.line(to:NSPoint(x:608,y:454))
    n.line(to:NSPoint(x:608,y:698)); n.line(to:NSPoint(x:694,y:698))
    n.line(to:NSPoint(x:694,y:326)); n.line(to:NSPoint(x:606,y:326))
    n.line(to:NSPoint(x:416,y:570)); n.line(to:NSPoint(x:416,y:326)); n.close()
    (dark && !tile ? NSColor(srgbRed:0.96,green:0.95,blue:0.91,alpha:1) : NSColor(srgbRed:0.09,green:0.10,blue:0.12,alpha:1)).setFill(); n.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return data
}

let catalog = root.appendingPathComponent("niko-shot/Resources/Assets.xcassets")
let icons = catalog.appendingPathComponent("AppIcon.appiconset")
for logical in [16,32,128,256,512] {
    for scale in [1,2] {
        let name = "icon_\(logical)\(scale == 1 ? "" : "@2x").png"
        try image(size: logical * scale, tile: true).write(to: icons.appendingPathComponent(name))
    }
}
let mark = catalog.appendingPathComponent("NikoMark.imageset")
try FileManager.default.createDirectory(at: mark, withIntermediateDirectories: true)
try image(size:256,tile:false).write(to:mark.appendingPathComponent("mark.png"))
try image(size:256,tile:false,dark:true).write(to:mark.appendingPathComponent("mark-dark.png"))
let contents = """
{"images":[{"idiom":"universal","filename":"mark.png"},{"idiom":"universal","filename":"mark-dark.png","appearances":[{"appearance":"luminosity","value":"dark"}]}],"info":{"author":"xcode","version":1}}
"""
try Data(contents.utf8).write(to:mark.appendingPathComponent("Contents.json"))
try image(size:512,tile:true).write(to:root.appendingPathComponent("website/assets/app-icon.png"))
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title"><title id="title">NIKO capture monogram</title><rect x="62" y="62" width="900" height="900" rx="202" fill="#faf5e8" stroke="#d6cfba" stroke-width="4"/><g fill="none" stroke="#e8a333" stroke-width="46" stroke-linecap="round" stroke-linejoin="round"><path d="M342 234H234V342M682 234H790V342M342 790H234V682M682 790H790V682"/></g><path d="M330 698V326H418L608 570V326H694V698H606L416 454V698Z" fill="#171a1f"/></svg>
"""
try Data(svg.utf8).write(to:root.appendingPathComponent("website/assets/niko-mark.svg"))
print("NIKO brand assets generated.")
