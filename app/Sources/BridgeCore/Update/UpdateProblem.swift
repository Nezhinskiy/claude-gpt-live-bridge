/// Why an update check or install stopped. Each case has one sentence for the Settings window
/// and the menu.
public enum UpdateProblem: Error, Equatable, Sendable {
  /// GitHub could not be reached or its reply was not a release, in the system's words.
  case network(String)
  /// GitHub answered with this status.
  case http(Int)
  /// The latest release's tag is not `vX.Y.Z`.
  case badTag(String)
  /// The latest release has no `LiveBridge.dmg`.
  case noImage
  /// The image is over the 100 MB limit.
  case tooLarge
  /// `gh` is not installed, so the image cannot be verified.
  case ghMissing
  /// `gh` is not signed in, so the image cannot be verified.
  case ghSignedOut
  /// `gh attestation verify` did not pass for the image.
  case attestationFailed
  /// The image's SHA-256 is not the one the attestation names.
  case digestMismatch
  /// The image holds no `LiveBridge.app`.
  case noApp
  /// The app in the image has another bundle identifier.
  case wrongBundle(String)
  /// The app in the image is not the release's version.
  case wrongVersion(String)
  /// The app in the image needs a newer macOS than this one, named by its minimum.
  case needsNewerMacOS(String)
  /// The app in the image fails its code signature check.
  case signatureInvalid
  /// `/Applications` is not writable by this user.
  case notWritable
  /// The staged copy changed after it was checked.
  case stagedChanged
  /// Putting the new app in place failed, in the system's words.
  case swapFailed(String)
  /// The release is not newer than the running app, so installing it would be a downgrade.
  case notNewer
  /// An install is already running.
  case busy
  /// This app is not the copy in `/Applications`.
  case notInstalledCopy
  /// The install stopped after the mod was updated to this version: the mod is new, the app is
  /// not.
  indirect case modAlreadyUpdated(UpdateProblem, version: AppVersion)

  /// One sentence for the owner.
  public var sentence: String {
    switch self {
    case .network(let detail): "LiveBridge could not check for an update: \(detail)"
    case .http(let status): "GitHub answered the update check with status \(status)."
    case .badTag(let tag): "The latest release is tagged \(tag), which is not a version."
    case .noImage: "The latest release has no LiveBridge.dmg."
    case .tooLarge: "The update image is larger than LiveBridge allows."
    case .ghMissing:
      "LiveBridge cannot verify the image without the GitHub CLI (gh); the release page has it."
    case .ghSignedOut:
      "LiveBridge cannot verify the image until gh is signed in; the release page has it."
    case .attestationFailed:
      "LiveBridge cannot verify the image came from the release workflow; the release page has it."
    case .digestMismatch: "The downloaded image is not the one GitHub attested."
    case .noApp: "The update image does not hold LiveBridge.app."
    case .wrongBundle(let identifier): "The update is the app \(identifier), not LiveBridge."
    case .wrongVersion(let version): "The update says it is version \(version), not the release."
    case .needsNewerMacOS(let minimum): "This update needs macOS \(minimum) or newer."
    case .signatureInvalid: "The update's code signature is not valid."
    case .notWritable: "LiveBridge cannot write to /Applications."
    case .stagedChanged: "The update changed after it was checked, so it was not installed."
    case .swapFailed(let detail): "The update could not replace the app: \(detail)"
    case .notNewer:
      "This release is not newer than the running LiveBridge, so it was not installed."
    case .busy: "An update is already running."
    case .notInstalledCopy: "Updates install only into /Applications."
    case .modAlreadyUpdated(let problem, let version):
      "\(problem.sentence) LiveBridge's Claude Code mod is already \(version), but the app was not "
        + "replaced; install again from Settings > Updates."
    }
  }
}
