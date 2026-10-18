import Foundation

struct ApplicationDisplayNameResolver {
    private let preferredLanguages: () -> [String]
    private let fileManager: FileManager

    init(
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
        fileManager: FileManager = .default
    ) {
        self.preferredLanguages = preferredLanguages
        self.fileManager = fileManager
    }

    func displayName(
        for applicationURL: URL,
        bundle suppliedBundle: Bundle? = nil,
        fallbackName: String? = nil
    ) -> String {
        let bundle = suppliedBundle ?? Bundle(url: applicationURL)

        if let bundle,
           let localizedName = systemLocalizedDisplayName(in: bundle) {
            return localizedName
        }

        if let bundle,
           let localizedName = displayName(in: bundle.localizedInfoDictionary) {
            return localizedName
        }

        if let bundle,
           let unlocalizedName = displayName(in: bundle.infoDictionary) {
            return unlocalizedName
        }

        if let fallbackName = nonEmpty(fallbackName) {
            return fallbackName
        }

        let fileName = fileManager.displayName(atPath: applicationURL.path)
        if !fileName.isEmpty {
            return (fileName as NSString).deletingPathExtension
        }
        return applicationURL.deletingPathExtension().lastPathComponent
    }

    func relocalize(_ application: PinnedApplication) -> PinnedApplication {
        PinnedApplication(
            identity: application.identity,
            bundleIdentifier: application.bundleIdentifier,
            applicationURL: application.applicationURL,
            displayName: displayName(
                for: application.applicationURL,
                fallbackName: application.displayName
            ),
            sourceOrder: application.sourceOrder
        )
    }

    private func systemLocalizedDisplayName(in bundle: Bundle) -> String? {
        if let displayName = localizationTableDisplayName(in: bundle) {
            return displayName
        }

        let availableLocalizations = bundle.localizations.filter { $0 != "Base" }
        guard !availableLocalizations.isEmpty else { return nil }

        let preferredLocalizations = Bundle.preferredLocalizations(
            from: availableLocalizations,
            forPreferences: preferredLanguages()
        )
        for localization in preferredLocalizations {
            guard let url = bundle.url(
                forResource: "InfoPlist",
                withExtension: "strings",
                subdirectory: nil,
                localization: localization
            ),
            let data = try? Data(contentsOf: url),
            let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            let displayName = displayName(in: dictionary) else {
                continue
            }
            return displayName
        }
        return nil
    }

    private func localizationTableDisplayName(in bundle: Bundle) -> String? {
        guard let url = bundle.url(
            forResource: "InfoPlist",
            withExtension: "loctable"
        ),
        let data = try? Data(contentsOf: url),
        let table = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return nil
        }

        let availableLocalizations = table.compactMap { localization, value in
            value is [String: Any] ? localization : nil
        }
        guard !availableLocalizations.isEmpty else { return nil }

        let preferredLocalizations = Bundle.preferredLocalizations(
            from: availableLocalizations,
            forPreferences: preferredLanguages()
        )
        for localization in preferredLocalizations {
            guard let dictionary = table[localization] as? [String: Any],
                  let displayName = displayName(in: dictionary) else {
                continue
            }
            return displayName
        }
        return nil
    }

    private func displayName(in dictionary: [String: Any]?) -> String? {
        nonEmpty(dictionary?["CFBundleDisplayName"] as? String)
            ?? nonEmpty(dictionary?["CFBundleName"] as? String)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
