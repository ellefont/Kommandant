import Foundation

// The German UI text is used as the key; translations live in Localization/<lang>.lproj/Localizable.strings
// and are copied into the app bundle by build.sh. macOS picks the language from the system settings
// (German, English, Italian; English for every other language).

/// Translates a German source string into the current UI language.
func t(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Translates a format string (German key) and fills in the arguments.
func t(_ key: String, _ args: CVarArg...) -> String {
    String(format: t(key), locale: Fmt.locale, arguments: args)
}
