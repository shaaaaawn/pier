import AppKit

/// The menu bar item's text: the TCP port count, a bullet for unseen events,
/// and — only under memory pressure — the count in orange or red.
///
/// Never `contentTintColor`. Tinting the whole button recolours the template
/// glyph too, and on macOS 26 a tinted item hosted by Control Center rendered
/// with no visible glyph at all (an on-screen slot that drew nothing, in dark
/// mode). The glyph stays a plain template image, which the system draws black
/// or white to match the menu bar; only the digits carry the colour.
///
/// Colours are the dynamic system ones, resolved against the menu bar's own
/// appearance at draw time: orange rather than yellow for Warning, because
/// yellow text disappears on a light menu bar.
enum StatusTitle {
  static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }

  static func make(count: Int, unseen: Int, pressure: MemoryPressure) -> NSAttributedString {
    let title = NSMutableAttributedString(string: " \(count)", attributes: [.font: font])
    if let colour = pressure.statusTint {
      title.addAttribute(
        .foregroundColor, value: colour, range: NSRange(location: 0, length: title.length))
    }
    if unseen > 0 {
      // No colour: inherits the menu bar's, like the glyph.
      title.append(NSAttributedString(string: " •", attributes: [.font: font]))
    }
    return title
  }
}
