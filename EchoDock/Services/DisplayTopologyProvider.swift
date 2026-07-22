import AppKit
import CoreGraphics
import ColorSync

struct DisplayIdentityCandidate {
    let base: DisplayIdentity
    let displayID: CGDirectDisplayID
    let frame: CGRect
}

enum DisplayIdentityUniquifier {
    static func uniquify(_ candidates: [DisplayIdentityCandidate]) -> [DisplayIdentity] {
        var result = candidates.map(\.base)
        var groups: [DisplayIdentity: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            groups[candidate.base, default: []].append(index)
        }

        for (base, indices) in groups where indices.count > 1 {
            let ordered = indices.sorted { lhs, rhs in
                let left = candidates[lhs]
                let right = candidates[rhs]
                if left.displayID != right.displayID {
                    return left.displayID < right.displayID
                }
                return frameToken(left.frame) < frameToken(right.frame)
            }

            var used = Set<String>()
            for index in ordered {
                let candidate = candidates[index]
                var rawValue = "\(base.rawValue):instance:\(candidate.displayID)"
                if used.contains(rawValue) {
                    rawValue += ":position:\(frameToken(candidate.frame))"
                }
                var ordinal = 2
                let seed = rawValue
                while used.contains(rawValue) {
                    rawValue = "\(seed):\(ordinal)"
                    ordinal += 1
                }
                used.insert(rawValue)
                result[index] = DisplayIdentity(rawValue: rawValue)
            }
        }
        return result
    }

    private static func frameToken(_ frame: CGRect) -> String {
        [frame.minX, frame.minY, frame.width, frame.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ":")
    }
}

final class DisplayTopologyProvider {
    func currentDisplays() -> [DisplayDescriptor] {
        let records = NSScreen.screens.compactMap { screen -> (screen: NSScreen, displayID: CGDirectDisplayID, mirroredID: CGDirectDisplayID, baseIdentity: DisplayIdentity)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let mirroredID = CGDisplayMirrorsDisplay(displayID)
            return (
                screen: screen,
                displayID: displayID,
                mirroredID: mirroredID,
                baseIdentity: makeIdentity(displayID: displayID, screen: screen)
            )
        }

        let identities = DisplayIdentityUniquifier.uniquify(records.map {
            DisplayIdentityCandidate(
                base: $0.baseIdentity,
                displayID: $0.displayID,
                frame: $0.screen.frame
            )
        })

        return records.enumerated().map { index, record in
            let displayID = record.displayID
            let mirroredID = record.mirroredID

            return DisplayDescriptor(
                identity: identities[index],
                displayID: displayID,
                localizedName: record.screen.localizedName,
                frame: record.screen.frame,
                isMain: CGDisplayIsMain(displayID) != 0,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                mirroredDisplayID: mirroredID == kCGNullDirectDisplay ? nil : mirroredID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.minY > rhs.frame.minY
        }
    }

    private func makeIdentity(displayID: CGDirectDisplayID, screen: NSScreen) -> DisplayIdentity {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtIn = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"

        if serial != 0 {
            return DisplayIdentity(rawValue: "display:\(vendor):\(model):\(serial)")
        }

        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            let uuidString = (CFUUIDCreateString(nil, uuid) as String).lowercased()
            return DisplayIdentity(rawValue: "display:uuid:\(uuidString)")
        }

        let normalizedName = screen.localizedName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        // Display IDs are the last-resort discriminator for virtual/adapter displays
        // that expose neither a serial number nor a UUID.
        return DisplayIdentity(rawValue: "display:\(vendor):\(model):\(builtIn):\(normalizedName):id:\(displayID)")
    }
}
