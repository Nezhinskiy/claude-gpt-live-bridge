import AppKit
import BridgeCore
import SwiftUI

/// Settings' last section (the spec's "What the owner sees"): the running version, Check for
/// update and its outcome or step, Install, the automatic check, and what the last update left.
/// Only the copy in `/Applications` updates; any other says so instead of offering the controls.
struct UpdateSection: View {
  @Bindable var model: AppModel

  var body: some View {
    Section("Updates") {
      LabeledContent {
        if model.updater != nil {
          Button("Check for update") { model.checkForUpdate() }.disabled(isRunning)
        }
      } label: {
        Text("LiveBridge \(model.versionText)")
      }
      if !model.isInstalledCopy {
        Text(UpdateProblem.notInstalledCopy.sentence)
          .font(.caption).foregroundStyle(.secondary)
      } else if model.updater != nil {
        outcome
        Toggle("Check for updates automatically", isOn: automatic)
      }
      record
    }
  }

  /// A check or install is under way, so another cannot start.
  private var isRunning: Bool { step != nil }

  /// The step a run is at, as the line shows it.
  private var step: String? {
    switch model.updateStatus {
    case .checking: "Checking"
    case .downloading: "Downloading"
    case .verifying: "Verifying"
    case .waiting: "Waiting for Claude to finish"
    case .updatingMod: "Updating the mod"
    case .installing: "Installing"
    case .idle, .upToDate, .available, .failed: nil
    }
  }

  /// The step of the run under way, or the outcome of the last check or install.
  @ViewBuilder private var outcome: some View {
    if let step {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(step)
      }
    } else {
      switch model.updateStatus {
      case .upToDate: Text("Up to date")
      case .available(let release):
        LabeledContent("Version \(release.version.description) is available") {
          Button("Install") { model.installUpdate() }
        }
      case .failed(let problem):
        VStack(alignment: .leading, spacing: 6) {
          Label(problem.sentence, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).symbolRenderingMode(.multicolor)
          if problem.offersReleasePage, let release = model.available {
            Link("Open the release page", destination: release.pageURL)
          }
        }
      default: EmptyView()
      }
    }
  }

  /// The toggle shows the build's default until the owner sets it.
  private var automatic: Binding<Bool> {
    Binding {
      model.checksAutomatically
    } set: { on in
      model.settings.update { $0.checkUpdatesAutomatically = on }
    }
  }

  /// What the last update left: the version it came from, and what became of the mod.
  @ViewBuilder private var record: some View {
    if let record = model.updateRecord {
      VStack(alignment: .leading, spacing: 6) {
        Text("Updated from \(record.from.description).")
        switch record.mod {
        case .updated:
          Text("Claude Code sessions already open keep the old mod until they restart.")
            .font(.caption).foregroundStyle(.secondary)
        case .byHand(let commands):
          Text("LiveBridge could not update its Claude Code mod. Run these in a terminal:")
            .font(.caption).foregroundStyle(.secondary)
          Text(commands.joined(separator: "\n"))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
          Button("Copy Commands") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
          }
        }
      }
    }
  }
}
