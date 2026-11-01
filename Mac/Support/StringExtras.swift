import Foundation

extension String {
    /// nil for an empty string, so `a.nilIfEmpty ?? b` falls back.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
