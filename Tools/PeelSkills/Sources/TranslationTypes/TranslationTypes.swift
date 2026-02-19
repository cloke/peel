//
//  TranslationTypes.swift
//  PeelSkills / TranslationTypes
//
//  Canonical location for shared Translation validation model types.
//  Used by both the TranslationValidator CLI and the Peel app
//  (via a mirrored copy in Shared/Services/TranslationValidatorService.swift).
//
//  If you modify these types, update the app-side copy as well.
//

import Foundation

// MARK: - Report Models

public struct TranslationReport: Codable, Sendable {
  public var roots: [TranslationRootReport]
  public init(roots: [TranslationRootReport] = []) { self.roots = roots }
}

public struct TranslationRootReport: Codable, Sendable {
  public var path: String
  public var baseLocale: String
  public var locales: [String]
  public var files: [FileReport]

  public init(path: String = "", baseLocale: String = "", locales: [String] = [], files: [FileReport] = []) {
    self.path = path
    self.baseLocale = baseLocale
    self.locales = locales
    self.files = files
  }
}

public struct FileReport: Codable, Sendable {
  public var file: String
  public var localesMissingFile: [String]
  public var missingKeys: [LocaleKeyList]
  public var extraKeys: [LocaleKeyList]
  public var placeholderMismatches: [PlaceholderMismatch]
  public var typeMismatches: [TypeMismatch]
  public var suspectTranslations: [SuspectTranslation]

  public init(
    file: String = "",
    localesMissingFile: [String] = [],
    missingKeys: [LocaleKeyList] = [],
    extraKeys: [LocaleKeyList] = [],
    placeholderMismatches: [PlaceholderMismatch] = [],
    typeMismatches: [TypeMismatch] = [],
    suspectTranslations: [SuspectTranslation] = []
  ) {
    self.file = file
    self.localesMissingFile = localesMissingFile
    self.missingKeys = missingKeys
    self.extraKeys = extraKeys
    self.placeholderMismatches = placeholderMismatches
    self.typeMismatches = typeMismatches
    self.suspectTranslations = suspectTranslations
  }
}

public struct LocaleKeyList: Codable, Sendable {
  public var locale: String
  public var keys: [String]
  public init(locale: String = "", keys: [String] = []) {
    self.locale = locale
    self.keys = keys
  }
}

public struct PlaceholderMismatch: Codable, Sendable {
  public var key: String
  public var locale: String
  public var expected: [String]
  public var found: [String]
  public init(key: String = "", locale: String = "", expected: [String] = [], found: [String] = []) {
    self.key = key
    self.locale = locale
    self.expected = expected
    self.found = found
  }
}

public struct TypeMismatch: Codable, Sendable {
  public var key: String
  public var locale: String
  public var expected: ValueKind
  public var found: ValueKind
  public init(key: String = "", locale: String = "", expected: ValueKind = .unknown, found: ValueKind = .unknown) {
    self.key = key
    self.locale = locale
    self.expected = expected
    self.found = found
  }
}

public struct SuspectTranslation: Codable, Sendable {
  public var key: String
  public var locale: String
  public var reason: String
  public var baseSample: String?
  public var localeSample: String?
  public init(key: String = "", locale: String = "", reason: String = "", baseSample: String? = nil, localeSample: String? = nil) {
    self.key = key
    self.locale = locale
    self.reason = reason
    self.baseSample = baseSample
    self.localeSample = localeSample
  }
}

public enum ValueKind: String, Codable, Sendable {
  case string
  case number
  case array
  case object
  case null
  case unknown
}

public enum IssueKind: String, CaseIterable, Sendable {
  case missing
  case extra
  case placeholders
  case types
  case suspects
}
