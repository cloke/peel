import XCTest
@testable import Github

final class GithubTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(Github().text, "Hello, World!")
    }
}
