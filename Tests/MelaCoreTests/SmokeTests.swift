import XCTest
@testable import MelaCore
final class SmokeTests: XCTestCase { func testVersion() { XCTAssertEqual(MelaCore.version, "0.1.0") } }
