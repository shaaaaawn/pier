import AppKit

/// The menu bar item's text beside the glyph — usually **nothing**. A port
/// count used to sit here; it changed every few seconds without telling you
/// anything actionable, and it widened an item in a bar that's often full.
///
/// Two marks remain, each only while it means something:
/// - `●` in orange or red while the kernel reports memory pressure;
/// - `•` in the menu bar's own colour while there are unseen start/stop events.
///
/// Never `contentTintColor`. Tinting the whole button recolours the template
/// glyph too, and on macOS 26 a tinted item hosted by Control Center rendered
/// with no visible glyph at all (an on-screen slot that drew nothing, in dark
/// mode). The glyph stays a plain template image, which the system draws black
/// or white to match the menu bar; only the pressure dot carries colour, and
/// its colours resolve per appearance (see `MemoryPressure.statusTint`).
enum StatusTitle {
  static var font: NSFont { .systemFont(ofSize: 12) }

  static func make(unseen: Int, pressure: MemoryPressure) -> NSAttributedString {
    let title = NSMutableAttributedString()
    if let colour = pressure.statusTint {
      title.append(
        NSAttributedString(
          string: " ●",
          attributes: [
            // Smaller than the text and lifted to sit mid-glyph: a 12pt ●
            // outweighed the icon it annotates.
            .font: NSFont.systemFont(ofSize: 8), .baselineOffset: 2, .foregroundColor: colour,
          ]))
    }
    if unseen > 0 {
      // No colour: inherits the menu bar's, like the glyph.
      title.append(NSAttributedString(string: " •", attributes: [.font: font]))
    }
    return title
  }
}
