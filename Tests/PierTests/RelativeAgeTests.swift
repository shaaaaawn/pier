import XCTest

@testable import Pier

/// The static stand-in for `Text(date, style: .relative)` shown while the panel
/// is hidden, and in every fixture render — so it has to read the same.
final class RelativeAgeTests: XCTestCase {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func age(_ seconds: TimeInterval) -> String {
    RelativeAge.string(since: now.addingTimeInterval(-seconds), now: now)
  }

  func testMatchesTheRelativeStyleTwoUnitsAtMost() throws {
    guard Locale.current.language.languageCode == .english else {
      throw XCTSkip("unit names are localized")
    }
    XCTAssertEqual(age(0), "0 sec")
    XCTAssertEqual(age(12), "12 sec")
    // `.relative` keeps the trailing zero: "2 min, 0 sec", not "2 min".
    XCTAssertEqual(age(120), "2 min, 0 sec")
    XCTAssertEqual(age(3 * 3600 + 5 * 60 + 9), "3 hr, 5 min")
  }

  func testAFutureDateStillReadsAsAnAge() {
    XCTAssertEqual(age(-12), age(12))
  }
}
