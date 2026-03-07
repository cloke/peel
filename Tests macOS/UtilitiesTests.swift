import XCTest
@testable import Peel

@MainActor
final class UtilitiesTests: XCTestCase {
  
  // MARK: - TextSanitizer Tests
  
  func testTextSanitizerBasicSanitization() {
    let input = "Hello World"
    let result = TextSanitizer.sanitize(input)
    XCTAssertEqual(result, "Hello World")
  }
  
  func testTextSanitizerEmptyString() {
    let result = TextSanitizer.sanitize("")
    XCTAssertEqual(result, "")
  }
  
  func testTextSanitizerWhitespaceOnly() {
    let result = TextSanitizer.sanitize("   \n\t   ")
    XCTAssertEqual(result, "")
  }
  
  func testTextSanitizerRemovesNullBytes() {
    let input = "Hello\u{0000}World"
    let result = TextSanitizer.sanitize(input)
    // Null bytes are removed (not replaced with space), then whitespace is collapsed
    XCTAssertEqual(result, "HelloWorld")
  }
  
  func testTextSanitizerRemovesControlCharacters() {
    let input = "Hello\u{0001}\u{0002}World"
    let result = TextSanitizer.sanitize(input)
    // Control characters are removed (not replaced with space)
    XCTAssertEqual(result, "HelloWorld")
  }
  
  func testTextSanitizerCollapsesWhitespace() {
    let input = "Hello    World  \n\n  Test"
    let result = TextSanitizer.sanitize(input)
    XCTAssertEqual(result, "Hello World Test")
  }
  
  func testTextSanitizerTrimsWhitespace() {
    let input = "  Hello World  "
    let result = TextSanitizer.sanitize(input)
    XCTAssertEqual(result, "Hello World")
  }
  
  func testTextSanitizerPreservesExtendedUnicode() {
    let input = "Hello 世界 🌍"
    let result = TextSanitizer.sanitize(input)
    XCTAssertEqual(result, "Hello 世界 🌍")
  }
  
  func testTextSanitizerTruncatesLongText() {
    let input = String(repeating: "a", count: 20_000)
    let result = TextSanitizer.sanitize(input)
    XCTAssertEqual(result.count, 10_000)
  }
  
  func testTextSanitizerForPromptRedactsEmail() {
    let input = "Contact me at test@example.com for details"
    let result = TextSanitizer.sanitizeForPrompt(input)
    XCTAssertEqual(result, "Contact me at <email> for details")
  }
  
  func testTextSanitizerForPromptRedactsSSN() {
    let input = "SSN: 123-45-6789"
    let result = TextSanitizer.sanitizeForPrompt(input)
    XCTAssertEqual(result, "SSN: <ssn>")
  }
  
  func testTextSanitizerForPromptRedactsPhone() {
    let input = "Call me at +1 (555) 123-4567"
    let result = TextSanitizer.sanitizeForPrompt(input)
    XCTAssertTrue(result.contains("<phone>"))
  }
  
  func testTextSanitizerForPromptRedactsNumbers() {
    let input = "Account number: 123456789"
    let result = TextSanitizer.sanitizeForPrompt(input)
    // 9-digit number matches SSN pattern (\d{3}-?\d{2}-?\d{4}) before the generic number pattern
    XCTAssertEqual(result, "Account number: <ssn>")
  }
  
  func testTextSanitizerForPromptKeepsShortNumbers() {
    let input = "Use version 1.2.3 for the API"
    let result = TextSanitizer.sanitizeForPrompt(input)
    // Short numbers (3 digits or less) should not be redacted
    XCTAssertTrue(result.contains("1.2.3"))
  }
  
  func testTextSanitizerForPromptEmptyString() {
    let result = TextSanitizer.sanitizeForPrompt("")
    XCTAssertEqual(result, "")
  }
  
  // MARK: - BranchNameSanitizer Tests
  
  func testBranchNameSanitizerBasicSanitization() {
    let input = "Feature Request"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-request")
  }
  
  func testBranchNameSanitizerLowercases() {
    let input = "FEATURE-BRANCH"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-branch")
  }
  
  func testBranchNameSanitizerReplacesSlashes() {
    let input = "feature/new-feature"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-new-feature")
  }
  
  func testBranchNameSanitizerReplacesBackslashes() {
    let input = "feature\\new-feature"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-new-feature")
  }
  
  func testBranchNameSanitizerReplacesColons() {
    let input = "feature:new-feature"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-new-feature")
  }
  
  func testBranchNameSanitizerReplacesSpaces() {
    let input = "my feature branch"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "my-feature-branch")
  }
  
  func testBranchNameSanitizerRemovesSpecialCharacters() {
    let input = "feature@#$%branch"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-branch")
  }
  
  func testBranchNameSanitizerCollapsesHyphens() {
    let input = "feature---branch"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-branch")
  }
  
  func testBranchNameSanitizerTrimsHyphens() {
    let input = "-feature-branch-"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature-branch")
  }
  
  func testBranchNameSanitizerPreservesAlphanumerics() {
    let input = "feature123branch456"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "feature123branch456")
  }
  
  func testBranchNameSanitizerComplexInput() {
    let input = "Fix/Bug #123: Update User Profile!"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "fix-bug-123-update-user-profile")
  }
  
  func testBranchNameSanitizerEmptyString() {
    let input = ""
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "")
  }
  
  func testBranchNameSanitizerSpecialCharactersOnly() {
    let input = "@#$%^&*()"
    let result = BranchNameSanitizer.sanitize(input)
    XCTAssertEqual(result, "")
  }

  // MARK: - RAG Orphan Audit Support Tests

  func testRAGOrphanAuditSupportParsesBaselineTablePaths() {
    let markdown = """
    | File | Category | Reason |
    |------|----------|--------|
    | `Shared/PeelApp.swift` | Entry | App entry |
    | `Shared/AgentOrchestration/MCPServerService+ServerCore.swift` | Extension | Same-module extension |
    """

    let paths = RAGOrphanAuditSupport.parseBaselinePaths(from: markdown)

    XCTAssertTrue(paths.contains("Shared/PeelApp.swift"))
    XCTAssertTrue(paths.contains("Shared/AgentOrchestration/MCPServerService+ServerCore.swift"))
    XCTAssertEqual(paths.count, 2)
  }

  func testRAGOrphanAuditSupportFiltersNonCodeAndBaselineEntries() {
    let repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let docsDir = repoRoot.appendingPathComponent("Docs/reference", isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
      let baseline = "| File | Category | Reason |\n|------|----------|--------|\n| `Shared/PeelApp.swift` | Entry | App entry |\n"
      try baseline.write(
        to: docsDir.appendingPathComponent("RAG_ORPHAN_BASELINE.md"),
        atomically: true,
        encoding: .utf8
      )

      let results = [
        RAGToolOrphanResult(
          filePath: "Shared/PeelApp.swift",
          language: "Swift",
          lineCount: 10,
          symbolsDefinedCount: 1,
          symbolsDefined: ["PeelApp"],
          reason: "Entry point"
        ),
        RAGToolOrphanResult(
          filePath: "Docs/PRODUCT_MANUAL.md",
          language: "Markdown",
          lineCount: 10,
          symbolsDefinedCount: 0,
          symbolsDefined: [],
          reason: "Doc"
        ),
        RAGToolOrphanResult(
          filePath: "Shared/Services/Useful.swift",
          language: "Swift",
          lineCount: 10,
          symbolsDefinedCount: 1,
          symbolsDefined: ["Useful"],
          reason: "Candidate"
        )
      ]

      let filtered = RAGOrphanAuditSupport.filter(
        results,
        repoPath: repoRoot.path,
        requestedLimit: 10,
        includeNonCode: false,
        respectBaseline: true,
        baselinePathOverride: nil
      )

      XCTAssertEqual(filtered.orphans.map(\.filePath), ["Shared/Services/Useful.swift"])
      XCTAssertEqual(filtered.suppressedBaselinePaths, ["Shared/PeelApp.swift"])
      XCTAssertEqual(filtered.suppressedNonCodePaths, ["Docs/PRODUCT_MANUAL.md"])
      XCTAssertEqual(filtered.baselinePath, docsDir.appendingPathComponent("RAG_ORPHAN_BASELINE.md").path)
    } catch {
      XCTFail("Unexpected file-system error: \(error)")
    }
  }
}
