import SwiftUI
import WebKit

/// Owns the WKWebView and load state for one inline port preview.
final class PreviewController: NSObject, ObservableObject, WKNavigationDelegate {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  static let timeout: TimeInterval = 10

  @Published private(set) var state: LoadState = .idle
  /// Non-persistent store: a previewed dev server's cookies, localStorage and
  /// caches would otherwise be written into Pier's container and outlive the
  /// preview. Nothing a preview loads should survive it.
  let webView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
  }()
  private var lastURL: URL?
  private var timeoutItem: DispatchWorkItem?

  override init() {
    super.init()
    webView.navigationDelegate = self
  }

  func load(_ url: URL) {
    lastURL = url
    state = .loading
    scheduleTimeout()
    webView.load(URLRequest(url: url))
  }

  func reload() {
    if let url = lastURL { load(url) }
  }

  /// Give the page a desktop-width layout viewport. pageZoom reflows (unlike
  /// `magnification`, which only scales visually and clips), so a 1280px
  /// target makes responsive sites choose their desktop breakpoint. Applied
  /// before load so the first layout is already at the right width.
  func applyViewport(_ viewport: PreviewViewport, cardWidth: CGFloat) {
    let zoom = viewport.zoom(cardWidth: cardWidth)
    guard abs(webView.pageZoom - zoom) > 0.001 else { return }
    webView.pageZoom = zoom
  }

  /// Debug: report the CSS viewport the page actually sees.
  func probeViewport(_ completion: @escaping (String) -> Void) {
    webView.evaluateJavaScript(
      "JSON.stringify({innerWidth: window.innerWidth, innerHeight: window.innerHeight})"
    ) { result, error in
      completion(result as? String ?? error?.localizedDescription ?? "nil")
    }
  }

  private func scheduleTimeout() {
    timeoutItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.state == .loading else { return }
      self.webView.stopLoading()
      self.state = .failed("Timed out after \(Int(Self.timeout))s")
    }
    timeoutItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: item)
  }

  private func fail(_ error: Error) {
    // stopLoading() (timeout, reload race) surfaces as a cancelled error.
    if (error as NSError).code == NSURLErrorCancelled { return }
    timeoutItem?.cancel()
    state = .failed(error.localizedDescription)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    timeoutItem?.cancel()
    state = .loaded
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    fail(error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail(error)
  }
}

struct WebViewRepresentable: NSViewRepresentable {
  let controller: PreviewController

  func makeNSView(context: Context) -> WKWebView {
    controller.webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Quiet 2pt Safari-style indeterminate progress bar for the card top.
private struct IndeterminateBar: View {
  @State private var phase: CGFloat = 0.2

  var body: some View {
    GeometryReader { geo in
      Capsule()
        .fill(Color.accentColor.opacity(0.85))
        .frame(width: geo.size.width * 0.3, height: 2)
        .offset(x: phase * geo.size.width)
        .onAppear {
          withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            phase = 1.0
          }
        }
    }
    .frame(height: 2)
    .clipped()
  }
}

/// Icon button with a hover background, matching the row-action style.
private struct PreviewIconButton: View {
  let symbol: String
  let help: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 20)
        .background(
          Color.primary.opacity(hovering ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
  }
}

/// Inline preview expanded under a port row: address-bar pill (host:port,
/// click-to-copy, reload, open external) above a bordered browser card with
/// a quiet loading bar and a proper error state.
struct PortPreviewView: View {
  let entry: PortEntry
  /// Fixture hook: when set, skips the live WKWebView and renders this state
  /// with static placeholder content (for --render-fixture-preview).
  var fixtureState: PreviewController.LoadState? = nil
  /// Card width in points, used for the pageZoom → viewport math.
  var cardWidth: CGFloat = PortListView.panelWidth - 24

  @StateObject private var controller = PreviewController()
  @State private var urlCopied = false
  /// Preferred CSS viewport, remembered across expands and launches.
  @AppStorage("previewViewport") private var viewportRaw = PreviewViewport.desktop.rawValue

  private var viewport: PreviewViewport {
    PreviewViewport(rawValue: viewportRaw) ?? .desktop
  }

  private var state: PreviewController.LoadState {
    fixtureState ?? controller.state
  }

  var body: some View {
    VStack(spacing: 6) {
      addressBar
      browserCard
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .padding(.top, 2)
    .onAppear {
      guard fixtureState == nil, let url = entry.previewURL else { return }
      controller.applyViewport(viewport, cardWidth: cardWidth)
      controller.load(url)
    }
    .onChange(of: viewportRaw) { _ in
      guard fixtureState == nil else { return }
      controller.applyViewport(viewport, cardWidth: cardWidth)
    }
    // A panel resize changes the card width, so the zoom must be recomputed to
    // keep hitting the requested CSS viewport.
    .onChange(of: cardWidth) { _ in
      guard fixtureState == nil else { return }
      controller.applyViewport(viewport, cardWidth: cardWidth)
    }
  }

  // MARK: - Address bar

  private var addressBar: some View {
    HStack(spacing: 6) {
      Button {
        copyURL()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: urlCopied ? "checkmark" : "globe")
            .font(.system(size: 10))
            .foregroundStyle(urlCopied ? .green : .secondary)
          Text(entry.previewDisplayAddress ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .buttonStyle(.plain)
      .help("Copy \(entry.previewURL?.absoluteString ?? "")")
      Spacer(minLength: 6)
      viewportPicker
      PreviewIconButton(symbol: "arrow.clockwise", help: "Reload") {
        controller.reload()
      }
      PreviewIconButton(symbol: "arrow.up.forward.square", help: "Open in default browser") {
        openExternal()
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
    )
  }

  /// Compact viewport-width menu (1280 / 1440 / 1024 / Fit).
  private var viewportPicker: some View {
    Menu {
      ForEach(PreviewViewport.allCases) { option in
        Button {
          viewportRaw = option.rawValue
        } label: {
          if option == viewport {
            Label(option.label, systemImage: "checkmark")
          } else {
            Text(option.label)
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "macwindow")
          .font(.system(size: 9))
        Text(viewport.label)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
      }
      .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(viewport.help)
  }

  // MARK: - Browser card

  private var browserCard: some View {
    ZStack(alignment: .top) {
      webContent
      if state == .loading || state == .idle {
        IndeterminateBar()
      }
    }
    .frame(maxWidth: .infinity)
    // Monitor-shaped: 16:10 for the desktop presets, so the scaled-down page
    // has the proportions it was designed for.
    .frame(height: (cardWidth * viewport.aspect).rounded())
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private var webContent: some View {
    switch state {
    case .failed(let message):
      errorContent(message)
    default:
      if fixtureState != nil {
        placeholderContent
      } else {
        WebViewRepresentable(controller: controller)
      }
    }
  }

  /// Static stand-in for web content so fixture renders can show the chrome.
  private var placeholderContent: some View {
    ZStack {
      LinearGradient(
        colors: [Color(white: 0.17), Color(white: 0.11)],
        startPoint: .top, endPoint: .bottom
      )
      VStack(alignment: .leading, spacing: 10) {
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.14))
          .frame(width: 140, height: 10)
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.08))
          .frame(height: 7)
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.08))
          .frame(width: 220, height: 7)
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.primary.opacity(0.06))
          .frame(height: 120)
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.08))
          .frame(width: 180, height: 7)
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func errorContent(_ message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "network.slash")
        .font(.system(size: 20))
        .foregroundStyle(.tertiary)
      Text("No web preview available")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      Text(message)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.primary.opacity(0.03))
  }

  // MARK: - Actions

  private func copyURL() {
    guard let url = entry.previewURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
    urlCopied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      urlCopied = false
    }
  }

  private func openExternal() {
    // NSWorkspace.open honors the user's default browser.
    if let url = entry.previewURL {
      NSWorkspace.shared.open(url)
    }
  }
}
