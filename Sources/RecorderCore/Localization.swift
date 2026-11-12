import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static let preferenceKey = "appLanguage"
    public var id: String { rawValue }
    public var title: String { self == .english ? "English" : "简体中文" }

    /// Use English on first launch and when a saved preference is no longer supported.
    public static func resolve(_ preference: String?) -> AppLanguage {
        preference.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    public static var current: AppLanguage {
        resolve(UserDefaults.standard.string(forKey: preferenceKey))
    }
}

/// Keep both versions of a status message so changing languages also refreshes existing messages.
public struct LocalizedMessage: Sendable {
    public let english: String
    public let chinese: String

    public init(_ english: String, _ chinese: String) {
        self.english = english
        self.chinese = chinese
    }

    public init(error: Error) {
        if let error = error as? BilingualLocalizedError {
            self = error.localizedMessage
        } else {
            self.init(error.localizedDescription, error.localizedDescription)
        }
    }

    public func text(language: AppLanguage = .current) -> String {
        language == .english ? english : chinese
    }

    public static func + (lhs: LocalizedMessage, rhs: LocalizedMessage) -> LocalizedMessage {
        LocalizedMessage(lhs.english + rhs.english, lhs.chinese + rhs.chinese)
    }
}

public protocol BilingualLocalizedError: LocalizedError {
    var localizedMessage: LocalizedMessage { get }
}

extension BilingualLocalizedError {
    public var errorDescription: String? { localizedMessage.text() }
}

public enum L10n {
    public static func text(_ english: String, _ chinese: String, language: AppLanguage = .current) -> String {
        language == .english ? english : chinese
    }
}
