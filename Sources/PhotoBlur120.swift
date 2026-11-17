import UIKit
import CoreImage

enum PhotoBlur120 {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func render(_ source: UIImage, radius: Double) -> UIImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(1, 160 / max(source.size.width, source.size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let size = CGSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        guard let image = CIImage(image: small) else { return nil }
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0, min(48, radius)) / 4]).cropped(to: image.extent)
        guard let result = context.createCGImage(blurred, from: image.extent) else { return nil }
        return UIImage(cgImage: result)
    }
}
