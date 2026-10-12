import Foundation
import Testing
@testable import FolioKit

/// Folio's String Catalogs: the app's and FolioKit's.
struct LocalizationTests {
    static let languages = ["fr", "es", "de", "zh-Hans"]

    static var catalogs: [URL] {
        let tests = URL(filePath: #filePath).deletingLastPathComponent()
        let package = tests.deletingLastPathComponent().deletingLastPathComponent()
        return [
            package.appending(path: "Sources/FolioKit/Resources/Localizable.xcstrings"),
            package.deletingLastPathComponent().appending(path: "Folio/Localizable.xcstrings"),
            package.deletingLastPathComponent().appending(path: "Folio/InfoPlist.xcstrings"),
            package.deletingLastPathComponent().appending(path: "Folio/AppShortcuts.xcstrings"),
        ]
    }

    static func strings(in catalog: URL) throws -> [String: [String: Any]] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        return json?["strings"] as? [String: [String: Any]] ?? [:]
    }

    /// Every value a localization holds: its string, or each plural form.
    static func values(of localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [value]
        }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] ?? [:]
        return plural.values.compactMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    /// Format specifiers such as %@ and %lld, without positions, sorted.
    static func specifiers(in text: String) -> [String] {
        let pattern = /%(?:\d+\$)?(?:ll|l)?[@dfu]/
        return text.matches(of: pattern).map { match in
            String(match.output).replacing(/\d+\$/, with: "")
        }.sorted()
    }

    @Test(arguments: catalogs) func everyStringHasAllFourLanguages(_ catalog: URL) throws {
        let strings = try Self.strings(in: catalog)
        #expect(!strings.isEmpty)
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                #expect(localizations[language].map(Self.values(of:))?.isEmpty == false, "\(catalog.lastPathComponent): \(key) has no \(language)")
            }
        }
    }

    @Test(arguments: catalogs) func translationsKeepTheirPlaceholders(_ catalog: URL) throws {
        for (key, entry) in try Self.strings(in: catalog) {
            let expected = Self.specifiers(in: key)
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for (language, localization) in localizations {
                let isPlural = (localization["variations"] as? [String: Any])?["plural"] != nil
                for value in Self.values(of: localization) {
                    let found = Self.specifiers(in: value)
                    // A plural's "one" form may leave its number out.
                    let ok = found == expected || (isPlural && found.isEmpty && expected.count == 1)
                    #expect(ok, "\(language) of \(key): \(value)")
                }
            }
        }
    }

    @Test func folioKitSpeaksFrench() {
        let french = Bundle.module.localizedString(forKey: "No timetable", value: nil, table: nil, localizations: [Locale.Language(identifier: "fr")])
        #expect(french == "Aucun emploi du temps")
        let english = Bundle.module.localizedString(forKey: "No timetable", value: nil, table: nil, localizations: [Locale.Language(identifier: "en")])
        #expect(english == "No timetable")
    }
}
