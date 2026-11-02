import Testing

@testable import BridgeCore

struct LabelsTests {
  @Test func duplicateTitlesGetShortIdSuffix() {
    let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
    let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
    let c = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    let labels = Labels.disambiguate([(a, "Example session"), (b, "Example session"), (c, "Other")])
    #expect(labels == [a: "Example session · 0000", b: "Example session · 1111", c: "Other"])
  }

  @Test func sharedPrefixesGrowUntilUnique() {
    let a = SessionID(rawValue: "abcd1234")
    let b = SessionID(rawValue: "abcd5678")
    let labels = Labels.disambiguate([(a, "Example session"), (b, "Example session")])
    #expect(labels == [a: "Example session · abcd1", b: "Example session · abcd5"])
  }
}
