import AppKit

extension NSImage {
    /// Average artwork color, tuned into a vivid-but-dark tint that stays legible
    /// behind white text. Used to color the island background and scrubber.
    func islandAccentColor() -> NSColor? {
        guard
            let tiff = tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let ciImage = CIImage(bitmapImageRep: bitmap)
        else { return nil }

        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard
            let filter = CIFilter(
                name: "CIAreaAverage",
                parameters: [
                    kCIInputImageKey: ciImage,
                    kCIInputExtentKey: CIVector(cgRect: extent),
                ]
            ),
            let output = filter.outputImage
        else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let base = NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )

        guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Boost saturation so muddy averages still read as a hue, and clamp
        // brightness so white text keeps enough contrast.
        saturation = min(1, saturation * 1.6 + 0.08)
        brightness = min(max(brightness, 0.30), 0.58)
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
}
