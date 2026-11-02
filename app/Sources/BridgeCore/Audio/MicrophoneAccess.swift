import Foundation

/// macOS's answer for LiveBridge's use of the microphone. The app asks for it before the audio
/// page opens the microphone: WebKit's own request never reaches macOS for this app, so without
/// the app's request no prompt appears and the page hears nothing.
public enum MicrophoneAccess: Sendable, Equatable {
  case granted, undetermined, denied, restricted

  /// The Microphone pane of Privacy & Security.
  public static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

  /// The answer to the app's own request.
  public init(asked isGranted: Bool) { self = isGranted ? .granted : .denied }

  /// macOS has not been asked yet; asking shows its prompt.
  public var mustAsk: Bool { self == .undetermined }

  /// Why the call cannot use the microphone, or nil when it can (or must ask first).
  public var problem: Problem? {
    switch self {
    case .granted, .undetermined: nil
    case .denied, .restricted: .microphoneDenied
    }
  }
}
