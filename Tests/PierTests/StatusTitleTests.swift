import AppKit
import XCTest

@testable import Pier

/// The menu bar item's text: nothing, unless a mark means something. Colour
/// lives on the pressure dot only — never on the button — so the template
/// glyph always draws in the menu bar's own colour.
final class StatusTitleTests: XCTestCase {
  private func colour(_ title: NSAttributedString, at index: Int = 1) -> NSColor? {
    title.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
  }

  /// The usual state: just the glyph. No port count — it said nothing useful.
  func testQuietItemHasNoText() {
    XCTAssertEqual(StatusTitle.make(unseen: 0, pressure: .normal).length, 0)
  }

  func testUnseenEventsAddAPlainBullet() {
    let title = StatusTitle.make(unseen: 3, pressure: .normal)
    XCTAssertEqual(title.string, " •")
    XCTAssertNil(colour(title))
  }

  func testPressureAddsAColouredDot() {
    let title = StatusTitle.make(unseen: 2, pressure: .critical)
    XCTAssertEqual(title.string, " ● •")
    assertSameColour(colour(title), MemoryPressure.critical.statusTint)
    XCTAssertNil(colour(title, at: title.length - 1), "the unseen bullet keeps the bar's colour")
    assertSameColour(
      colour(StatusTitle.make(unseen: 0, pressure: .warning)), MemoryPressure.warning.statusTint)
  }

  /// Both modes: a dynamic system colour must resolve to something visible on
  /// a light *and* a dark menu bar. Checked as contrast against each bar.
  func testPressureColoursReadOnLightAndDarkBars() throws {
    for colour in [MemoryPressure.warning, .critical].compactMap(\.statusTint) {
      for (name, bar) in [(NSAppearance.Name.aqua, 0.93), (.darkAqua, 0.13)] {
        var resolved = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
          resolved = colour.usingColorSpace(.sRGB)!
        }
        let ratio = contrast(luminance(resolved), bar)
        XCTAssertGreaterThanOrEqual(ratio, 3, "\(colour) on \(name.rawValue): \(ratio)")
      }
    }
  }

  /// Why Warning isn't Activity Monitor's yellow: it fails on a light bar.
  func testYellowWouldVanishOnALightBar() {
    var resolved = NSColor.clear
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
      resolved = NSColor.systemYellow.usingColorSpace(.sRGB)!
    }
    XCTAssertLessThan(contrast(luminance(resolved), 0.93), 3)
  }

  /// Dynamic colours compare by what they draw as, in both appearances.
  private func assertSameColour(
    _ a: NSColor?, _ b: NSColor?, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let a, let b else { return XCTFail("missing colour", file: file, line: line) }
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      var (ra, rb) = (NSColor.clear, NSColor.clear)
      NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        ra = a.usingColorSpace(.sRGB)!
        rb = b.usingColorSpace(.sRGB)!
      }
      XCTAssertEqual(ra, rb, "\(name.rawValue)", file: file, line: line)
    }
  }

  private func luminance(_ c: NSColor) -> Double {
    func ch(_ v: CGFloat) -> Double {
      let v = Double(v)
      return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722
      * ch(c.blueComponent)
  }

  private func contrast(_ a: Double, _ grey: Double) -> Double {
    let g = grey <= 0.03928 ? grey / 12.92 : pow((grey + 0.055) / 1.055, 2.4)
    let (hi, lo) = (max(a, g), min(a, g))
    return (hi + 0.05) / (lo + 0.05)
  }
}
