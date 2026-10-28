import AppKit

/// Pier's mark for the menu bar and the panel header: a pier in profile —
/// deck, three pilings, one lit lamp at the end — over a line of water. The
/// app icon's scene, reduced to what survives 16pt.
///
/// Drawn as paths rather than shipped as PNGs, so it's sharp at every scale,
/// and a template image, so AppKit paints it in the menu bar's own foreground
/// colour — dark on a light bar, light on a dark one, tinted while the panel
/// is open. Geometry is on a 16-unit grid; `size` scales it.
enum PierGlyph {
  static func image(size: CGFloat = 16) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
      let u = rect.width / 16
      NSColor.black.set()
      func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat) {
        NSBezierPath(
          roundedRect: NSRect(x: x * u, y: y * u, width: w * u, height: h * u),
          xRadius: radius * u, yRadius: radius * u
        ).fill()
      }
      // The lamp and its post, standing at the seaward end.
      NSBezierPath(ovalIn: NSRect(x: 11.3 * u, y: 1.2 * u, width: 3.4 * u, height: 3.4 * u)).fill()
      bar(12.45, 4, 1.1, 4, radius: 0.4)
      // Deck.
      bar(0.5, 7.8, 15, 1.8, radius: 0.9)
      // Pilings, stopping short of the water so the line reads on its own;
      // the last one carries the lamp post down to it.
      for x: CGFloat in [2.2, 7.3, 12.3] {
        bar(x, 9.2, 1.4, 3.9, radius: 0.35)
      }
      // Water: two periods of a low swell.
      let wave = NSBezierPath()
      wave.lineWidth = 1.2 * u
      wave.lineCapStyle = .round
      var x: CGFloat = 1
      let half: CGFloat = 3.5
      wave.move(to: NSPoint(x: x * u, y: 14.8 * u))
      for crest in [true, false, true, false] {
        let control = (crest ? 14.0 : 15.6) * u
        wave.curve(
          to: NSPoint(x: (x + half) * u, y: 14.8 * u),
          controlPoint1: NSPoint(x: (x + half / 3) * u, y: control),
          controlPoint2: NSPoint(x: (x + half * 2 / 3) * u, y: control))
        x += half
      }
      wave.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }
}
