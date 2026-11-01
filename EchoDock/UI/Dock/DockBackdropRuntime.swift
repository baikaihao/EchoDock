import AppKit
import QuartzCore

enum DockLiquidGlassRuntime {
    static func makeBackdropLayer() -> CALayer? {
        DockGaussianBackdropRuntime.makeBehindWindowLayer()
    }

    static func isBackdropLayer(_ layer: CALayer) -> Bool {
        DockGaussianBackdropRuntime.isBackdropLayer(layer)
    }

    static func makeFilter(type: String, name: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let unmanagedFilter = filterClass.perform(
                  NSSelectorFromString("filterWithType:"),
                  with: type
              ),
              let filter = unmanagedFilter.takeUnretainedValue()
                as? NSObject else {
            return nil
        }
        filter.setValue(name, forKey: "name")
        return filter
    }

    static func filter(
        _ filter: NSObject,
        supports requiredInputs: Set<String>
    ) -> Bool {
        let availableInputs = Set(
            filter.value(forKey: "inputKeys") as? [String] ?? []
        )
        return requiredInputs.isSubset(of: availableInputs)
    }

    static func setProperty(_ value: Any, key: String, on object: NSObject) {
        let setterName = "set"
            + key.prefix(1).uppercased()
            + String(key.dropFirst())
            + ":"
        guard object.responds(to: NSSelectorFromString(setterName)) else { return }
        object.setValue(value, forKey: key)
    }
}

enum DockGaussianBackdropRuntime {
    private static let backdropLayerClassName = "CABackdropLayer"
    private static let filterClassName = "CAFilter"

    static func makeBehindWindowLayer() -> CALayer? {
        guard let layerClass = NSClassFromString(backdropLayerClassName)
            as? NSObject.Type,
              let unmanagedLayer = layerClass.perform(
                NSSelectorFromString("behindWindowLayer")
              ),
              let layer = unmanagedLayer.takeUnretainedValue() as? CALayer else {
            return nil
        }

        let scaleSetter = NSSelectorFromString("setScale:")
        if layer.responds(to: scaleSetter) {
            layer.setValue(CGFloat(1), forKey: "scale")
        }
        return layer
    }

    static func isBackdropLayer(_ layer: CALayer) -> Bool {
        guard let layerClass = NSClassFromString(backdropLayerClassName) else {
            return false
        }
        return layer.isKind(of: layerClass)
    }

    static func makeGaussianBlurFilter() -> NSObject? {
        guard let filterClass = NSClassFromString(filterClassName) as? NSObject.Type,
              let unmanagedFilter = filterClass.perform(
                NSSelectorFromString("filterWithType:"),
                with: "gaussianBlur"
              ),
              let filter = unmanagedFilter.takeUnretainedValue() as? NSObject else {
            return nil
        }
        filter.setValue("echoDockGaussianBlur", forKey: "name")
        filter.setValue(0, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(true, forKey: "inputDither")
        return filter
    }
}

final class DockGaussianBackdropView: NSView {
    override func makeBackingLayer() -> CALayer {
        DockGaussianBackdropRuntime.makeBehindWindowLayer()
            ?? super.makeBackingLayer()
    }

    var backdropLayer: CALayer? {
        guard let layer, DockGaussianBackdropRuntime.isBackdropLayer(layer) else {
            return nil
        }
        return layer
    }
}
