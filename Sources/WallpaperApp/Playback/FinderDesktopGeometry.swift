import Foundation
import CoreGraphics

struct FinderScreenGeometry: Equatable, Sendable {
    let quartzBounds: CGRect
    let appKitFrame: CGRect

    func appKitPoint(for point: CGPoint) -> CGPoint? {
        let values = [point.x, point.y, quartzBounds.minX, quartzBounds.minY, quartzBounds.width,
                      quartzBounds.height, appKitFrame.minX, appKitFrame.minY, appKitFrame.width, appKitFrame.height]
        guard values.allSatisfy(\.isFinite), quartzBounds.width > 0, quartzBounds.height > 0,
              appKitFrame.width > 0, appKitFrame.height > 0, quartzBounds.contains(point) else { return nil }
        let x = (point.x - quartzBounds.minX) / quartzBounds.width
        let y = (point.y - quartzBounds.minY) / quartzBounds.height
        return CGPoint(x: appKitFrame.minX + x * appKitFrame.width,
                       y: appKitFrame.maxY - y * appKitFrame.height)
    }
}
