import Foundation
import CoreGraphics

/// A display-local capture rectangle in top-left logical points, aligned inward
/// to physical pixels. No point outside the drag selection is captured.
public struct CaptureRegion: Equatable, Sendable {
    public let sourceRect: CGRect
    public let pixelSize: CGSize

    public init(appKitRect: CGRect, displaySize: CGSize, pixelScale: CGFloat) throws {
        let values = [appKitRect.origin.x, appKitRect.origin.y, appKitRect.width, appKitRect.height,
                      displaySize.width, displaySize.height, pixelScale]
        guard values.allSatisfy(\.isFinite), pixelScale > 0,
              displaySize.width > 0, displaySize.height > 0 else {
            throw ValidationError.invalidCaptureRegion
        }
        let bounded = appKitRect.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !bounded.isNull, !bounded.isEmpty else { throw ValidationError.invalidCaptureRegion }
        let left = ceil(bounded.minX * pixelScale)
        let top = ceil((displaySize.height - bounded.maxY) * pixelScale)
        let width = floor((floor(bounded.maxX * pixelScale) - left) / 2) * 2
        let height = floor((floor((displaySize.height - bounded.minY) * pixelScale) - top) / 2) * 2
        guard width >= 2, height >= 2 else { throw ValidationError.invalidCaptureRegion }
        sourceRect = CGRect(x: left / pixelScale, y: top / pixelScale,
                            width: width / pixelScale, height: height / pixelScale)
        pixelSize = CGSize(width: width, height: height)
    }
}
