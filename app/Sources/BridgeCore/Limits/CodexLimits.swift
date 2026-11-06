import Foundation

/// The usage windows codex reports for the signed-in account (`account/rateLimits/read`,
/// experimental).
public enum CodexLimits {
  /// The `codex` bucket's five-hour and week windows, and whether codex says ordinary usage is
  /// blocked. Windows are told apart by their length, never by slot: codex passes the backend's
  /// primary and secondary through, and either may be null or hold the week. Only the window
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
    var limits = UsageLimits(readAt: now)
    if case .bool(false)? = reply["ordinaryUsageAllowed"] { limits.isBlocked = true }
    guard let bucket = codexBucket(reply) else { return limits }
    for slot in ["primary", "secondary"] {
      guard let window = bucket[slot], let minutes = window["windowDurationMins"]?.number,
        let percent = window["usedPercent"]?.number
      else { continue }
      let found = LimitWindow(
        usedPercent: percent,
        resetsAt: window["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) })
      if length(minutes, near: 300) {
        if limits.fiveHour == nil { limits.fiveHour = found }
      } else if length(minutes, near: 10080) {
        if limits.week == nil { limits.week = found }
      }
    }
    return limits
  }

  /// `rateLimitsByLimitId.codex`, else the single-bucket `rateLimits` when its `limitId` is
  /// `codex` or absent. Other buckets are per-model quotas and are not ordinary Codex usage.
  private static func codexBucket(_ reply: JSONValue) -> JSONValue? {
    if let bucket = reply["rateLimitsByLimitId"]?["codex"], bucket.object != nil { return bucket }
    guard let single = reply["rateLimits"], single.object != nil else { return nil }
    let id = single["limitId"]
    return id == nil || id == .null || id?.string == "codex" ? single : nil
  }

  /// Within 5 % of `target` minutes, ends included, as codex labels windows.
  private static func length(_ minutes: Double, near target: Double) -> Bool {
    abs(minutes - target) <= target * 0.05
  }
}
