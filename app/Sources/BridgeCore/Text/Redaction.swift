import Foundation

/// Removes credentials from text before the voice hears it or the menu shows it. Named
/// patterns only, so commit SHAs, ids and hashes are kept; there is no entropy rule.
public enum Redaction {
  public static let mask = "(redacted)"

  /// Each pattern with its replacement; `$1` keeps a prefix such as a field name.
  static let rules: [(NSRegularExpression, String)] = [
    (#"-----BEGIN ([A-Z ]+)-----[\s\S]*?-----END \1-----"#, mask),
    (#"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, mask),  // JWT
    (#"\bsk-[A-Za-z0-9_-]{16,}"#, mask),
    (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, mask),
    (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, mask),
    (#"\bxox[abpr]-[A-Za-z0-9-]{10,}"#, mask),
    (#"\bAKIA[0-9A-Z]{16}\b"#, mask),
    // a credential has a digit or a symbol, so "Basic understanding" is kept
    (#"\b(Bearer|Basic)\s+(?=[A-Za-z]*[0-9._~+/=-])[A-Za-z0-9._~+/=-]{8,}"#, "$1 \(mask)"),
    (#"(://)[^/\s:@]+:[^/\s@]+@"#, "$1\(mask)@"),  // URL userinfo
    (
      #"(?i)([A-Za-z0-9_-]*(?:password|passwd|secret|token|api[_-]?key)[A-Za-z0-9_-]*["']?\s*[:=]\s*["']?)[^\s"',;]+"#,
      "$1\(mask)"
    ),
  ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

  public static func redact(_ text: String) -> String {
    rules.reduce(text) { text, rule in
      rule.0.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
    }
  }
}
