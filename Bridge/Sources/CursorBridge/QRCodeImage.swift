import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeImage {
    static func make(from string: String, dimension: CGFloat = 180) -> NSImage? {
        guard !string.isEmpty else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale = dimension / output.extent.width
        var scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = scaled.extent.origin
        if origin.x != 0 || origin.y != 0 {
            scaled = scaled.transformed(
                by: CGAffineTransform(translationX: -origin.x, y: -origin.y)
            )
        }
        let rect = scaled.extent.integral

        let contexts = [
            CIContext(options: [.useSoftwareRenderer: true]),
            CIContext(),
        ]
        for context in contexts {
            guard let cgImage = context.createCGImage(scaled, from: rect) else { continue }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: dimension, height: dimension))
            image.isTemplate = false
            return image
        }
        return nil
    }
}
