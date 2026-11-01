import BridgeCore
import SwiftUI

/// The menu bar popover: the call, the sessions, the target's context line and last lines (each
/// session has its own conversation with the voice), the minutes, and the app's own settings.
/// Liquid Glass on macOS 26 and later, materials before. It never grows past the screen's
/// visible height (a taller menu bar window leaves a transparent band at its top): the sessions,
/// the last lines and what was sent scroll inside their own caps, and past the screen the whole
/// popover scrolls.
struct PopoverView: View {
  @Bindable var model: AppModel
  @State private var showContext = false
  @State private var copied = false

  private var layout: PopoverLayout {
    PopoverLayout(visibleHeight: Double(NSScreen.main?.visibleFrame.height ?? 800))
  }

  var body: some View {
    GlassGroup {
      CappedScroll(cap: layout.maxHeight) { content }
    }
    .frame(width: 340)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let shown = model.presentation {
        call(shown)
        if let problem = model.problem {
          problemBanner(problem, opensSettings: shown.opensMicrophoneSettings)
        }
        sessions(shown)
        context
        if !(model.status?.recentTranscript.isEmpty ?? true) { lastLines }
        footer(shown)
      } else {
        if let problem = model.problem { problemBanner(problem) } else { ProgressView() }
        Button("Quit LiveBridge") { NSApplication.shared.terminate(nil) }
      }
    }
    .padding(12)
  }

  private func call(_ shown: StatusPresentation) -> some View {
    HStack(spacing: 10) {
      Image(nsImage: model.glyph.image)
        .renderingMode(.template)
        .foregroundStyle(tint(shown.tint))
        .frame(width: 36, height: 36)
        .background(tint(shown.tint).opacity(0.18), in: .circle)
      VStack(alignment: .leading, spacing: 2) {
        Text(shown.headline).font(.headline)
        Text(shown.detail).font(.caption).foregroundStyle(.secondary)
        if shown.unheard > 0 {
          Label("\(shown.unheard) unheard — speak to hear", systemImage: "circle.fill")
            .font(.caption2).foregroundStyle(.tint)
        }
      }
      Spacer()
      Button(shown.action == .start ? "Start" : "Stop") { model.perform(shown.action) }
        .capsule(prominent: shown.action == .start)
        .disabled(!shown.canAct)
    }
    .card()
  }

  private func problemBanner(_ problem: String, opensSettings: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(problem, systemImage: "exclamationmark.triangle.fill")
        .font(.callout).symbolRenderingMode(.multicolor).lineLimit(6)
      if opensSettings {
        Button("Open Microphone Settings", systemImage: "mic") {
          NSWorkspace.shared.open(MicrophoneAccess.settingsURL)
        }
        .capsule(prominent: false)
      }
    }
    .card()
  }

  private func sessions(_ shown: StatusPresentation) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Sessions").font(.caption).foregroundStyle(.secondary)
      if shown.offersJoinCommand {
        HStack {
          Text("No session has joined.")
            .font(.callout).foregroundStyle(.secondary)
          Spacer()
          copyJoinCommand
        }
      }
      CappedScroll(cap: layout.sessions) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(shown.rows) { row in
            HStack(spacing: 4) {
              targetButton(row)
              Button {
                model.remove(row)
              } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .frame(width: 22, height: 22).contentShape(.rect)
              }
              .buttonStyle(.plain)
              .help("Remove from LiveBridge and erase its conversation; /live on joins it again")
              .accessibilityLabel("Remove \(row.label) from LiveBridge")
            }
          }
        }
      }
    }
    .card()
  }

  /// Copies `/live on`, to paste into a Claude Code session; says so for two seconds.
  private var copyJoinCommand: some View {
    Button(
      copied ? "Copied" : "Copy \(StatusPresentation.joinCommand)",
      systemImage: copied ? "checkmark" : "doc.on.doc"
    ) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(StatusPresentation.joinCommand, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(2))
        copied = false
      }
    }
    .capsule(prominent: false)
    .help("Copy \(StatusPresentation.joinCommand), then run it in a Claude Code session")
  }

  private func targetButton(_ row: SessionRowPresentation) -> some View {
    Button {
      model.setTarget(row.id)
    } label: {
      HStack {
        Image(systemName: row.isTarget ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(row.isTarget ? Color.accentColor : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(row.label).lineLimit(1)
          Label(row.detail, systemImage: Self.symbol(of: row.activity))
            .font(.caption)
            .foregroundStyle(row.activity == .approval ? .orange : .secondary)
        }
        Spacer()
      }
      .padding(6)
      .background(
        row.isTarget ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(row.isTarget ? .isSelected : [])
  }

  private static func symbol(of activity: SessionActivity) -> String {
    switch activity {
    case .idle: "moon.zzz"
    case .working: "arrow.triangle.2.circlepath"
    case .approval: "exclamationmark.circle"
    }
  }

  private var context: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button(model.contextLoad.title, systemImage: model.contextLoad.symbol) {
          model.loadContext()
        }
        .disabled(!model.contextLoad.isEnabled)
        .help("Ask the target session for a summary of its work, for the voice")
        Button("New conversation", systemImage: "square.and.pencil") { model.newConversation() }
          .help("Erase the voice's conversation with the target session")
      }
      .capsule(prominent: false)
      if let sent = model.status?.lastContext {
        DisclosureGroup("What was sent", isExpanded: $showContext) {
          CappedScroll(cap: layout.sent) {
            Text(sent).font(.caption).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.top, 4)
        }
        .font(.caption)
      }
    }
    .card()
  }

  /// The target's label; the context line and the last lines are its conversation's.
  private var target: String? { model.status?.sessions.first(where: \.isTarget)?.label }

  private var lastLines: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(target.map { "Last lines with \($0)" } ?? "Last lines")
        .font(.caption).foregroundStyle(.secondary)
      CappedScroll(cap: layout.lastLines) {
        VStack(alignment: .leading, spacing: 4) {
          let lines = (model.status?.recentTranscript ?? []).map(TranscriptLine.init)
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .firstTextBaseline) {
              Text(line.speaker).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
              Text(line.text).lineLimit(4).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
          }
        }
      }
    }
    .card()
  }

  private func footer(_ shown: StatusPresentation) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(shown.minutes).font(.caption).foregroundStyle(.secondary)
      Toggle("Open at login", isOn: $model.openAtLogin).toggleStyle(.switch)
      Button("Quit LiveBridge") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q").buttonStyle(.plain)
    }
    .padding(.horizontal, 4)
  }

  private func tint(_ tint: Tint) -> Color {
    switch tint {
    case .quiet: .secondary
    case .active: .teal
    case .attention: .orange
    case .problem: .red
    }
  }
}

/// A vertical scroll view as tall as its content, up to `cap` points; past it, it scrolls. A
/// plain ScrollView in a menu bar window takes no height of its own, so the content's height is
/// measured.
private struct CappedScroll<Content: View>: View {
  let cap: Double
  @ViewBuilder var content: Content
  @State private var height = 0.0

  var body: some View {
    ScrollView(.vertical) {
      content.onGeometryChange(for: Double.self) {
        Double($0.size.height)
      } action: {
        height = $0
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(height, cap))
  }
}

/// Liquid Glass where the system has it (macOS 26 and later), materials before. Its symbols
/// exist only in the macOS 26 SDK (Swift 6.2, Xcode 26), so an older Xcode builds the materials.
private struct GlassGroup<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    #if compiler(>=6.2)
      if #available(macOS 26, *) { GlassEffectContainer(spacing: 10) { content } } else { content }
    #else
      content
    #endif
  }
}

extension View {
  @ViewBuilder fileprivate func card() -> some View {
    let padded = frame(maxWidth: .infinity, alignment: .leading).padding(10)
    #if compiler(>=6.2)
      if #available(macOS 26, *) {
        padded.glassEffect(.regular, in: .rect(cornerRadius: 16))
      } else {
        padded.background(.regularMaterial, in: .rect(cornerRadius: 16))
      }
    #else
      padded.background(.regularMaterial, in: .rect(cornerRadius: 16))
    #endif
  }

  @ViewBuilder fileprivate func capsule(prominent: Bool) -> some View {
    #if compiler(>=6.2)
      if #available(macOS 26, *) {
        if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
      } else {
        buttonStyle(.bordered).buttonBorderShape(.capsule)
      }
    #else
      buttonStyle(.bordered).buttonBorderShape(.capsule)
    #endif
  }
}
