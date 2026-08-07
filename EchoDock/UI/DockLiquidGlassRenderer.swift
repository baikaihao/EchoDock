import CoreGraphics
import Foundation

struct DockLiquidGlassMapDescriptor: Equatable {
    let bodyHeight: CGFloat
    let cornerRadius: CGFloat
    let backingScale: CGFloat
    let optics: DockLiquidGlassOptics
}

struct DockLiquidGlassDisplacementMap {
    static let neutralChannel: UInt8 = 128

    let descriptor: DockLiquidGlassMapDescriptor
    let image: CGImage
    let rgba8: Data
    let widthPixels: Int
    let heightPixels: Int
    let contentsCenter: CGRect

    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        precondition((0..<widthPixels).contains(x))
        precondition((0..<heightPixels).contains(y))
        let offset = (y * widthPixels + x) * 4
        return (
            rgba8[offset],
            rgba8[offset + 1],
            rgba8[offset + 2],
            rgba8[offset + 3]
        )
    }
}

/// Generates the optical vector field consumed by Core Animation's compositor.
/// R/G encode signed displacement, B is rounded-rectangle coverage, and A is
/// deliberately opaque so antialiasing never premultiplies the vector channels.
enum DockLiquidGlassMapRenderer {
    static let displacementSourceLayerName =
        "echoDockLiquidGlassDisplacementMap"

    static func makeMap(
        descriptor: DockLiquidGlassMapDescriptor
    ) -> DockLiquidGlassDisplacementMap? {
        let scale = max(1, descriptor.backingScale)
        let heightPixels = max(1, Int(ceil(descriptor.bodyHeight * scale)))
        let radiusPixels = min(
            CGFloat(heightPixels) / 2,
            max(0, descriptor.cornerRadius * scale)
        )
        let optics = descriptor.optics
        let refractionBand = max(1, optics.innerRefractionHeight * scale)
        // Keep the stretch column farther from the synthetic left/right edges
        // than the full refraction band. Otherwise those edges flatten the SDF
        // gradient and prematurely stop top/bottom lensing after only a few px.
        let capWidthPixels = max(
            1,
            Int(ceil(radiusPixels + refractionBand + 2))
        )
        let widthPixels = capWidthPixels * 2 + 1
        let pixelCount = widthPixels * heightPixels
        guard pixelCount > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: pixelCount * 4)
        let size = CGSize(
            width: CGFloat(widthPixels),
            height: CGFloat(heightPixels)
        )
        let refractionStrength = abs(optics.innerRefractionAmount) * scale
        let maximumOffset = max(0.000_1, optics.maximumRefractionOffset * scale)
        let indexOfRefraction = max(1.000_1, optics.indexOfRefraction)

        for row in 0..<heightPixels {
            // CGImage's first row is the visual top edge.
            let y = CGFloat(heightPixels) - CGFloat(row) - 0.5
            for column in 0..<widthPixels {
                let x = CGFloat(column) + 0.5
                let point = CGPoint(x: x, y: y)
                let sdf = roundedRectSDF(
                    point: point,
                    size: size,
                    radius: radiusPixels
                )
                let coverage = 1 - smoothstep(-0.85, 0.85, sdf)
                let byteOffset = (row * widthPixels + column) * 4

                guard coverage > 0.000_1 else {
                    bytes[byteOffset] = DockLiquidGlassDisplacementMap.neutralChannel
                    bytes[byteOffset + 1] = DockLiquidGlassDisplacementMap.neutralChannel
                    bytes[byteOffset + 2] = 0
                    bytes[byteOffset + 3] = 255
                    continue
                }

                let gradient = sdfGradient(
                    point: point,
                    size: size,
                    radius: radiusPixels
                )
                let insideDepth = clamp(-sdf / refractionBand)
                let lensHeight = smoothstep(0, 1, insideDepth)
                let lateral = sqrt(max(0, 1 - lensHeight * lensHeight))
                let normalX = gradient.x * lateral
                let normalY = gradient.y * lateral
                let incidentDotNormal = -lensHeight
                let eta = 1 / indexOfRefraction
                let refractionRoot = sqrt(max(
                    0,
                    1 - eta * eta * (1 - incidentDotNormal * incidentDotNormal)
                ))
                let normalScale = eta * incidentDotNormal + refractionRoot
                let edgeWeight = 1 - smoothstep(0, 1, insideDepth)
                let offsetX = clampSigned(
                    -normalScale * normalX * refractionStrength * edgeWeight,
                    limit: maximumOffset
                )
                let offsetY = clampSigned(
                    -normalScale * normalY * refractionStrength * edgeWeight,
                    limit: maximumOffset
                )

                bytes[byteOffset] = channel(for: offsetX / maximumOffset)
                // Core Animation samples Y in the opposite direction.
                bytes[byteOffset + 1] = channel(for: -offsetY / maximumOffset)
                bytes[byteOffset + 2] = byte(for: coverage)
                bytes[byteOffset + 3] = 255
            }
        }

        let data = Data(bytes)
        guard let image = makeImage(
                  rgba8: data,
                  widthPixels: widthPixels,
                  heightPixels: heightPixels
              ) else {
            return nil
        }

        let imageWidth = CGFloat(widthPixels)
        let contentsCenter = CGRect(
            x: CGFloat(capWidthPixels) / imageWidth,
            y: 0,
            width: 1 / imageWidth,
            height: 1
        )
        return DockLiquidGlassDisplacementMap(
            descriptor: descriptor,
            image: image,
            rgba8: data,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            contentsCenter: contentsCenter
        )
    }

    private static func makeImage(
        rgba8: Data,
        widthPixels: Int,
        heightPixels: Int
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: rgba8 as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(
            width: widthPixels,
            height: heightPixels,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: widthPixels * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ).union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func roundedRectSDF(
        point: CGPoint,
        size: CGSize,
        radius: CGFloat
    ) -> CGFloat {
        let halfWidth = max(0.000_1, size.width / 2)
        let halfHeight = max(0.000_1, size.height / 2)
        let resolvedRadius = min(radius, min(halfWidth, halfHeight))
        let qx = abs(point.x - halfWidth) - halfWidth + resolvedRadius
        let qy = abs(point.y - halfHeight) - halfHeight + resolvedRadius
        return min(max(qx, qy), 0)
            + hypot(max(qx, 0), max(qy, 0))
            - resolvedRadius
    }

    private static func sdfGradient(
        point: CGPoint,
        size: CGSize,
        radius: CGFloat
    ) -> CGPoint {
        let step: CGFloat = 1
        let dx = roundedRectSDF(
            point: CGPoint(x: point.x + step, y: point.y),
            size: size,
            radius: radius
        ) - roundedRectSDF(
            point: CGPoint(x: point.x - step, y: point.y),
            size: size,
            radius: radius
        )
        let dy = roundedRectSDF(
            point: CGPoint(x: point.x, y: point.y + step),
            size: size,
            radius: radius
        ) - roundedRectSDF(
            point: CGPoint(x: point.x, y: point.y - step),
            size: size,
            radius: radius
        )
        let length = max(0.000_1, hypot(dx, dy))
        return CGPoint(x: dx / length, y: dy / length)
    }

    private static func channel(for normalizedOffset: CGFloat) -> UInt8 {
        byte(for: 0.5 + 0.5 * clampSigned(normalizedOffset, limit: 1))
    }

    private static func byte(for normalizedValue: CGFloat) -> UInt8 {
        UInt8((clamp(normalizedValue) * 255).rounded())
    }

    private static func smoothstep(
        _ lower: CGFloat,
        _ upper: CGFloat,
        _ value: CGFloat
    ) -> CGFloat {
        guard upper > lower else { return value < lower ? 0 : 1 }
        let resolved = clamp((value - lower) / (upper - lower))
        return resolved * resolved * (3 - 2 * resolved)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private static func clampSigned(
        _ value: CGFloat,
        limit: CGFloat
    ) -> CGFloat {
        min(limit, max(-limit, value))
    }
}
