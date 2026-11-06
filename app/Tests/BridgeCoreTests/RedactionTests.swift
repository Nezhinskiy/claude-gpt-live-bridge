import Testing

@testable import BridgeCore

struct RedactionTests {
  @Test(arguments: [
    ("key sk-proj-abcdefghijklmnop1234", "sk-proj"),
    ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_"),
    ("github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "github_pat_"),
    ("slack xoxb-1234567890-abcdefghij", "xoxb-"),
    ("aws AKIAABCDEFGHIJKLMNOP", "AKIA"),
    ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", "eyJ"),
    ("Authorization: Bearer abcdef123456789", "abcdef123"),
    ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpw"),
    ("-----BEGIN PRIVATE KEY-----\nMIIEexample\n-----END PRIVATE KEY-----", "MIIE"),
    ("clone https://user:hunter2@example.com/repo.git", "hunter2"),
    ("password: hunter2", "hunter2"), ("client_secret=abc123def", "abc123"),
    ("API_KEY = 'abc123def'", "abc123"), ("access_token: abc123def", "abc123"),
    ("AWS_SECRET_ACCESS_KEY=abc123def456", "abc123"),
    ("STRIPE_SECRET_KEY=sk_live_abc123def456", "sk_live"),
    ("DB_PASSWORD_PROD=hunter2", "hunter2"),
  ])
  func redactsNamedPattern(text: String, secret: String) {
    let redacted = Redaction.redact(text)
    #expect(!redacted.contains(secret) && redacted.contains("(redacted)"), "\(redacted)")
  }

  /// All typed text goes through this on the bridge's actor, so a pasted dump of the mod's 32,000
  /// characters must not hold up every session's poll.
  @Test(arguments: ["a3f9", "token", "secret_"])
  func aLongUnbrokenRunTakesNoTime(run: String) {
    let text = String(repeating: run, count: 32_000 / run.count)
    let took = ContinuousClock().measure { _ = Redaction.redact(text) }
    #expect(took < .seconds(1))
  }

  /// The field name may run on after the keyword, up to a limit that keeps the rule linear.
  @Test func aLongFieldNameIsStillAField() {
    let name = "api_key_" + String(repeating: "x", count: 56)
    #expect(Redaction.redact("\(name)=hunter2") == "\(name)=(redacted)")
  }

  @Test func keepsFullGitShas() {
    let shas =
      "commit 0123456789abcdef0123456789abcdef01234567 and "
      + String(repeating: "0123456789abcdef", count: 4)
    #expect(Redaction.redact(shas) == shas)
  }
}
