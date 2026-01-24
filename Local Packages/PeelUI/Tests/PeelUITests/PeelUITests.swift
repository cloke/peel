import XCTest
@testable import PeelUI

final class PeelUITests: XCTestCase {
  func testViewStateIdle() throws {
    let state: ViewState<String> = .idle
    XCTAssertFalse(state.isLoading)
    XCTAssertNil(state.value)
    XCTAssertNil(state.error)
  }
  
  func testViewStateLoading() throws {
    let state: ViewState<String> = .loading
    XCTAssertTrue(state.isLoading)
  }
  
  func testViewStateLoaded() throws {
    let state: ViewState<String> = .loaded("test")
    XCTAssertEqual(state.value, "test")
  }
  
  func testViewStateError() throws {
    let state: ViewState<String> = .error("Failed")
    XCTAssertEqual(state.error, "Failed")
  }
}
