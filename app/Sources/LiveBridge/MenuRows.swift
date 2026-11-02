import AppKit
import BridgeCore
import SwiftUI

/// The menu's custom rows, hosted in its items by `StatusMenu`. They use the menu's own type
/// sizes (13 pt titles, 11 pt subtitles) and insets, so they line up with the native items, and
/// a row that acts on a click draws the menu's selection highlight under the pointer.
enum MenuStyle {
  /// From the menu's edge to a row's text, as a native item's title sits.
  static let inset: CGFloat = 14
  /// From the menu's edge to the highlight, and the highlight's corners.
  static let highlightInset: CGFloat = 5
  static var highlightRadius: CGFloat { hasLiquidGlass ? 8 : 4 }
  static let title = Font.system(size: 13)
  static let subtitle = Font.system(size: 11)
}

/// The menu's first row: the call, its Start/Stop button, unheard results, and the problem
/// banner with its help. A click inside does not close the menu; only the buttons that leave it
/// (Open Microphone Settings) close it first.
struct CallCardView: View {
  let card: MenuContent.CallCard
  let glyph: StatusGlyph
  let menu: StatusMenu
  @State private var showHelp = false
  /// The command just copied, which its button says for two seconds.
  @State private var copied: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(nsImage: glyph.image)
          .renderingMode(.template)
          .foregroundStyle(tint)
          .frame(width: 32, height: 32)
          .background(tint.opacity(0.18), in: .circle)
        VStack(alignment: .leading, spacing: 1) {
          Text(card.headline).font(MenuStyle.title.weight(.semibold))
          if !card.detail.isEmpty {
            Text(card.detail).font(MenuStyle.subtitle).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let unheard = card.unheard {
            Label(unheard, systemImage: "circle.fill")
              .font(MenuStyle.subtitle).foregroundStyle(.tint)
          }
        }
        Spacer(minLength: 8)
        if let title = card.actionTitle, let action = card.action {
          Button(title) { menu.perform(action) }
            .capsule(prominent: action == .start)
            .disabled(!card.canAct)
        }
      }
      if let problem = card.problem { banner(problem) }
    }
    .padding(.horizontal, MenuStyle.inset)
    .padding(.vertical, 6)
  }

  private func banner(_ problem: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(problem, systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 12)).symbolRenderingMode(.multicolor)
        .fixedSize(horizontal: false, vertical: true)
      if card.opensMicrophoneSettings {
        Button("Open Microphone Settings", systemImage: "mic") {
          menu.closeThen { NSWorkspace.shared.open(MicrophoneAccess.settingsURL) }
        }
        .capsule(prominent: false)
      }
      if let help = card.codexHelp {
        Button(help.button, systemImage: showHelp ? "chevron.up" : "questionmark.circle") {
          showHelp.toggle()
        }
        .capsule(prominent: false)
        if showHelp {
          VStack(alignment: .leading, spacing: 8) {
            Text(help.steps).font(MenuStyle.subtitle).fixedSize(horizontal: false, vertical: true)
            Text(help.command).font(MenuStyle.subtitle.monospaced())
            copyButton(help.command, title: help.copy)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.fill.tertiary, in: .rect(cornerRadius: 10))
  }

  /// Copies `command`, to paste into Terminal; says so for two seconds, the menu staying open.
  private func copyButton(_ command: String, title: String) -> some View {
    Button(
      copied == command ? "Copied" : title,
      systemImage: copied == command ? "checkmark" : "doc.on.doc"
    ) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
      copied = command
      Task {
        try? await Task.sleep(for: .seconds(2))
        if copied == command { copied = nil }
      }
    }
    .capsule(prominent: false)
  }

  private var tint: Color {
    switch card.tint {
    case .quiet: .secondary
    case .active: .teal
    case .attention: .orange
    case .problem: .red
    }
  }
}

/// One session: its marker (filled for the target), its label and what it is doing, and ×.
/// A click makes it the target and leaves the menu open, so the marker moves; × closes the
/// menu, asks, then removes it.
struct SessionRowView: View {
  let row: SessionRowPresentation
  /// Its item's key, for the menu's highlight.
  let key: String
  let menu: StatusMenu
  @State private var hovering = false

  var body: some View {
    let lit = hovering || menu.highlight.contains(key)
    HStack(spacing: 6) {
      Button {
        menu.setTarget(row.id)
      } label: {
        HStack(spacing: 7) {
          Image(systemName: row.isTarget ? "largecircle.fill.circle" : "circle")
            .font(MenuStyle.title)
            .foregroundStyle(lit ? Self.selected : row.isTarget ? Color.accentColor : .secondary)
          VStack(alignment: .leading, spacing: 0) {
            Text(row.label).font(MenuStyle.title).lineLimit(1)
            Label(row.detail, systemImage: Self.symbol(of: row.activity))
              .font(MenuStyle.subtitle)
              .foregroundStyle(
                lit ? Self.selected.opacity(0.85) : row.activity == .approval ? .orange : .secondary
              )
          }
          Spacer(minLength: 0)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(row.isTarget ? .isSelected : [])
      .accessibilityHint("Makes this session the one the voice talks to")
      Button {
        menu.remove(row)
      } label: {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(lit ? Self.selected : .secondary)
          .frame(width: 20, height: 20).contentShape(.rect)
      }
      .buttonStyle(.plain)
      .help("Remove from LiveBridge and erase its conversation; /live on joins it again")
      .accessibilityLabel("Remove \(row.label) from LiveBridge")
    }
    .foregroundStyle(lit ? Self.selected : .primary)
    .padding(.horizontal, MenuStyle.inset - MenuStyle.highlightInset)
    .padding(.vertical, 3)
    .background {
      if lit {
        RoundedRectangle(cornerRadius: MenuStyle.highlightRadius)
          .fill(Color(nsColor: .selectedContentBackgroundColor))
      }
    }
    .padding(.horizontal, MenuStyle.highlightInset)
    .onHover { hovering = $0 }
  }

  private static let selected = Color(nsColor: .selectedMenuItemTextColor)

  private static func symbol(of activity: SessionActivity) -> String {
    switch activity {
    case .idle: "moon.zzz"
    case .working: "arrow.triangle.2.circlepath"
    case .approval: "exclamationmark.circle"
    }
  }
}

/// The target's whole conversation, oldest first; its item scrolls (`ScrollingItem`).
struct TranscriptView: View {
  let lines: [Conversation.Line]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(lines.indices, id: \.self) { LineView(line: lines[$0]) }
    }
    .padding(.vertical, 2)
  }
}

/// One line of the conversation, whole and wrapped: who said it, then what.
struct LineView: View {
  let line: Conversation.Line

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(line.speaker.name).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
      Text(line.text.trimmingCharacters(in: .whitespacesAndNewlines)).fixedSize(
        horizontal: false, vertical: true
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 12))
    .padding(.horizontal, MenuStyle.inset)
    .padding(.vertical, 2)
  }
}

/// The target's context line, as the voice got it, wrapped.
struct SentView: View {
  let text: String

  var body: some View {
    Text(text).font(MenuStyle.subtitle).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, MenuStyle.inset)
      .padding(.vertical, 2)
  }
}

extension View {
  /// The card's buttons: Liquid Glass capsules where the system has them (macOS 26 and later),
  /// bordered capsules before. Small, as controls in a menu are.
  @ViewBuilder fileprivate func capsule(prominent: Bool) -> some View {
    #if compiler(>=6.2)
      if #available(macOS 26, *) {
        if prominent {
          buttonStyle(.glassProminent).controlSize(.small)
        } else {
          buttonStyle(.glass).controlSize(.small)
        }
      } else {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
      }
    #else
      buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
    #endif
  }
}

private var hasLiquidGlass: Bool {
  #if compiler(>=6.2)
    if #available(macOS 26, *) { return true }
  #endif
  return false
}
