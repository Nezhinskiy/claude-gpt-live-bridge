/// The realtime voices codex offers (`thread/realtime/listVoices`, experimental).
public enum Voices {
  /// The voices for realtime V3, the version the app's sessions use. codex 0.166.0 answers
  /// `{voices: {v1, v2, v3, defaultV1, defaultV2}}` and names no V3 default, so the default is
  /// left to codex by sending no `voice`.
  public static func list(client: any RPCClient, timeout: Duration = .seconds(20)) async throws
    -> [String]
  {
    let reply: JSONValue = try await client.request(
      "thread/realtime/listVoices", JSONValue.object([:]), timeout: timeout)
    guard let v3 = reply["voices"]?["v3"]?.array else {
      throw CodexProblem.protocolMismatch("thread/realtime/listVoices without V3 voices")
    }
    return v3.compactMap(\.string)
  }
}
