import Foundation
import SwiftUI

enum DictionaryProvider: String, CaseIterable, Identifiable {
    case system, oxford, collins
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "macOS 本地词典"
        case .oxford: return "Oxford Dictionaries API"
        case .collins: return "Collins Dictionary API"
        }
    }
}

struct LookupConfiguration: Sendable {
    var provider: DictionaryProvider
    var oxfordAppID: String
    var oxfordAppKey: String
    var oxfordLanguage: String
    var oxfordChinese: Bool
    var collinsKey: String
    var collinsDictionary: String
}

struct DictionarySection: Identifiable, Sendable {
    let id = UUID()
    var heading: String
    var body: String
}

struct DictionaryResult: Sendable {
    var word: String
    var source: String
    var sections: [DictionarySection]
    var notice: String? = nil
    var sourceURL: URL? = nil
}

@MainActor final class LookupState: ObservableObject {
    @Published var word = ""
    @Published var isLoading = false
    @Published var result: DictionaryResult?
    @Published var error: String?
}

/// Only operational status is retained; never include selected text here.
@MainActor final class SelectionDiagnostics: ObservableObject {
    @Published var status = "等待选词操作。"
}

enum EnglishWord {
    /// Accept a single English headword, including contractions and hyphenated compounds.
    static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        let punctuation = CharacterSet(charactersIn: "\"“”.,;:!?()[]{}«»")
        let word = trimmed.trimmingCharacters(in: punctuation)
        guard !word.isEmpty, word.utf8.count <= 64,
              word.range(of: "^[A-Za-z]+(?:['-][A-Za-z]+)*$", options: .regularExpression) != nil else { return nil }
        return word.lowercased()
    }
}
