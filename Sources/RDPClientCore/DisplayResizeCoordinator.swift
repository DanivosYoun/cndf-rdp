import CoreGraphics
import Foundation

public struct RDPDesktopSize: Equatable, Sendable {
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let scale: Double

    public init(pixelWidth: UInt32, pixelHeight: UInt32, scale: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }
}

public final class DisplayResizeCoordinator {
    private let minimumPixelWidth: UInt32
    private let minimumPixelHeight: UInt32
    private let minimumInterval: TimeInterval
    private var lastSentSize: RDPDesktopSize?
    private var lastSentTime: TimeInterval?

    public init(
        minimumPixelWidth: UInt32 = 640,
        minimumPixelHeight: UInt32 = 480,
        minimumInterval: TimeInterval = 0.12
    ) {
        self.minimumPixelWidth = minimumPixelWidth
        self.minimumPixelHeight = minimumPixelHeight
        self.minimumInterval = minimumInterval
    }

    public func candidateSize(
        pointWidth: Double,
        pointHeight: Double,
        scale: Double,
        preferDeviceNativeResolution: Bool = true,
        forcedDesktopSize: CGSize? = nil
    ) -> RDPDesktopSize {
        if let forcedDesktopSize {
            let width = clampedPixelDimension(forcedDesktopSize.width)
            let height = clampedPixelDimension(forcedDesktopSize.height)
            return RDPDesktopSize(pixelWidth: width, pixelHeight: height, scale: 1.0)
        }

        let normalizedScale = preferDeviceNativeResolution ? max(scale, 1.0) : 1.0
        let width = max(minimumPixelWidth, UInt32((pointWidth * normalizedScale).rounded(.toNearestOrAwayFromZero)))
        let height = max(minimumPixelHeight, UInt32((pointHeight * normalizedScale).rounded(.toNearestOrAwayFromZero)))
        return RDPDesktopSize(pixelWidth: width, pixelHeight: height, scale: normalizedScale)
    }

    public func sizeToSend(
        pointWidth: Double,
        pointHeight: Double,
        scale: Double,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        force: Bool = false,
        preferDeviceNativeResolution: Bool = true,
        forcedDesktopSize: CGSize? = nil
    ) -> RDPDesktopSize? {
        let candidate = candidateSize(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            scale: scale,
            preferDeviceNativeResolution: preferDeviceNativeResolution,
            forcedDesktopSize: forcedDesktopSize
        )
        guard force || candidate != lastSentSize else {
            return nil
        }

        if !force, let lastSentTime, now - lastSentTime < minimumInterval {
            return nil
        }

        lastSentSize = candidate
        lastSentTime = now
        return candidate
    }

    private func clampedPixelDimension(_ value: CGFloat) -> UInt32 {
        UInt32(max(1, min(CGFloat(UInt32.max), value.rounded(.toNearestOrAwayFromZero))))
    }
}
