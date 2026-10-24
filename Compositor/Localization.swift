import Foundation

extension String {
    /// The translated text for this key from the app's Localizable.strings. The key is
    /// left as the English text, so English needs no table of its own: the literal is
    /// the fallback when a translation is missing.
    var localized: String { NSLocalizedString(self, comment: "") }
}
