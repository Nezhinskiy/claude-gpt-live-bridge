import Foundation

/// The usage windows codex reports for the signed-in account (`account/rateLimits/read`,
/// experimental).
public enum CodexLimits {
  /// Every window of the `codex` bucket, and whether codex says ordinary usage is blocked.
  /// Windows are told apart by their length, never by slot: codex passes the backend's primary
  /// and secondary through, and either may be null or hold any length. Two of one length keep the
  /// primary; a window with no length shows as `limit`. Only the window
  /// fields and `ordinaryUsageAllowed` are read; the account id and credits are never touched.
  public static func read(
    client: any RPCClient, now: Date, timeout: Duration = .seconds(10)
  ) async throws -> UsageLimits {
    let reply: JSONValue = try await client.request(
      "account/rateLimits/read", JSONValue.object(["excludeResetCreditDetails": true]),
      timeout: timeout)
    guard reply.object != nil else {
      throw CodexProblem.protocolMismatch("account/rateLimits/read without an object")
    }
    var windows: [LimitWindow] = []
    if let bucket = codexBucket(reply) {
      for slot in ["primary", "secondary"] {
        guard let window = bucket[slot], let percent = window["usedPercent"]?.number else {
          continue
        }
        windows.append(
          LimitWindow(
            span: LimitSpan(minutes: window["windowDurationMins"]?.number), usedPercent: percent,
            resetsAt: window["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) }))
      }
    }
    var blocked = false
    if case .bool(false)? = reply["ordinaryUsageAllowed"] { blocked = true }
    return UsageLimits(windows: windows, isBlocked: blocked, readAt: now)
  }

  /// `rateLimitsByLimitId.codex`, else the single-bucket `rateLimits` when its `limitId` is
  /// `codex` or absent. Other buckets are per-model quotas and are not ordinary Codex usage.
  private static func codexBucket(_ reply: JSONValue) -> JSONValue? {
    if let bucket = reply["rateLimitsByLimitId"]?["codex"], bucket.object != nil { return bucket }
    guard let single = reply["rateLimits"], single.object != nil else { return nil }
    let id = single["limitId"]
    return id == nil || id == .null || id?.string == "codex" ? single : nil
  }
}
