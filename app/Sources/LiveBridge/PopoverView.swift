import BridgeCore
import SwiftUI

/// The menu bar popover: the call, the sessions, the context last sent, the last lines, the
/// minutes, and the app's own settings. Liquid Glass on macOS 26 and later, materials before.
struct PopoverView: View {
  @Bindable var model: AppModel
  @State private var showContext = false

  var body: some View {
    GlassGroup {
      VStack(alignment: .leading, spacing: 10) {
        if let shown = model.presentation {
          call(shown)
          if let problem = model.problem { problemBanner(problem) }
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
    .frame(width: 340)
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

  private func problemBanner(_ problem: String) -> some View {
    Label(problem, systemImage: "exclamationmark.triangle.fill")
      .font(.callout).symbolRenderingMode(.multicolor)
      .card()
  }

  private func sessions(_ shown: StatusPresentation) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Sessions").font(.caption).foregroundStyle(.secondary)
      if shown.rows.isEmpty {
        Text("No session has joined.")
          .font(.callout).foregroundStyle(.secondary)
      }
      ForEach(shown.rows) { row in
        Button {
          model.setTarget(row.id)
        } label: {
          HStack {
            Image(systemName: row.isTarget ? "largecircle.fill.circle" : "circle")
              .foregroundStyle(row.isTarget ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text(row.label)
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
    }
    .card()
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
        Button("Load context", systemImage: "square.and.arrow.down") { model.loadContext() }
        Button("New conversation", systemImage: "square.and.pencil") { model.newConversation() }
      }
      .capsule(prominent: false)
      if let sent = model.status?.lastContext {
        DisclosureGroup("What was sent", isExpanded: $showContext) {
          Text(sent).font(.caption).textSelection(.enabled).padding(.top, 4)
        }
        .font(.caption)
      }
    }
    .card()
  }

  private var lastLines: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Last lines").font(.caption).foregroundStyle(.secondary)
      ForEach(Array((model.status?.recentTranscript ?? []).enumerated()), id: \.offset) { _, line in
        let parts = line.split(separator: ": ", maxSplits: 1)
        HStack(alignment: .firstTextBaseline) {
          Text(parts.count == 2 ? parts[0] : "").foregroundStyle(.secondary).frame(
            width: 44, alignment: .leading)
          Text(parts.last ?? "").fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
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
