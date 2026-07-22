import Foundation

private final class EchoDockLocalizationBundleToken: NSObject {}

enum L10n {
    private static let bundle = Bundle(for: EchoDockLocalizationBundleToken.self)

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
