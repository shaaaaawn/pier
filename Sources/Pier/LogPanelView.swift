import AppKit
import SwiftUI

/// Inline log tail under a row: a header naming the source, then a monospaced
/// scrollback pinned to the newest line. Mirrors the web preview's chrome so
/// both expansions feel like the same drawer.
struct LogPanelView: View {
  let source: LogSource
  let toolPath: String?
  var cmuxPassword: String?
  /// Fixture hook: static lines instead of launching a real tail.
  var fixtureLines: [String]?

  @StateObject private var tailer = LogTailer()
  @State private var isPinned = true
  @State private var copied = false

  private var lines: [String] { fixtureLines ?? tailer.lines }

  var body: some View {
    VStack(spacing: 6) {
      header
      content
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .padding(.top, 2)
    .onAppear {
      guard fixtureLines == nil else { return }
      tailer.start(source: source, toolPath: toolPath, cmuxPassword: cmuxPassword)
    }
    .onDisappear { tailer.stop() }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: source.isAvailable ? "text.alignleft" : "text.badge.xmark")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      Text(source.label)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(source.isAvailable ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 6)
      if source.isAvailable {
        if source.isStream {
          Button {
            isPinned.toggle()
          } label: {
            Image(systemName: isPinned ? "arrow.down.to.line" : "pause")
              .font(.system(size: 10))
          }
          .buttonStyle(.plain)
          .foregroundStyle(isPinned ? Color.accentColor : .secondary)
          .help(isPinned ? "Following new lines — click to hold position" : "Resume following")
        }
        Button {
          copyAll()
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? .green : .secondary)
        .help("Copy all \(lines.count) lines")
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

  // MARK: - Body

  @ViewBuilder
  private var content: some View {
    Group {
      if !source.isAvailable {
        message("No log to tail", detail: source.label, symbol: "text.badge.xmark")
      } else if case .ended(let why) = tailer.state, lines.isEmpty {
        message(why ?? "No output", detail: nil, symbol: "text.badge.xmark")
      } else if lines.isEmpty {
        message("Waiting for output…", detail: nil, symbol: "ellipsis")
      } else {
        logLines
      }
    }
    .frame(height: 200)
    .background(Color.black.opacity(0.22))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
    )
  }

  private var logLines: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(verbatim: line.isEmpty ? " " : line)
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(tint(for: line))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(index)
          }
        }
        .padding(8)
      }
      .onChange(of: lines.count) { count in
        guard isPinned, count > 0 else { return }
        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(count - 1, anchor: .bottom) }
      }
      .onAppear {
        if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
      }
    }
  }

  /// Errors and warnings earn color; everything else stays quiet so the eye
  /// finds the problem line instead of scanning uniformly bright text.
  private func tint(for line: String) -> Color {
    let lower = line.lowercased()
    if lower.contains("error") || lower.contains("fatal") || lower.contains("panic")
      || lower.contains("traceback")
    {
      return .red
    }
    if lower.contains("warn") { return .orange }
    return Color.primary.opacity(0.75)
  }

  private func message(_ title: String, detail: String?, symbol: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.system(size: 18))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      if let detail {
        Text(detail)
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 20)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func copyAll() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
  }
}
