import Foundation
import Testing

@testable import BridgeCore

struct ReleaseTests {
  @Test func aVersionParsesStrictly() {
    let version = AppVersion("0.1.2")
    #expect(version?.major == 0 && version?.minor == 1 && version?.patch == 2)
    for text in ["0.1", "01.1.2", "+1.1.2", "0.1.2-rc1", "1.2.3.4", "1234567.0.0", "", "1.2.x"] {
      #expect(AppVersion(text) == nil, "\(text)")
    }
  }

  @Test func versionsOrderAsIntegers() throws {
    #expect(try #require(AppVersion("0.1.10")) > #require(AppVersion("0.1.9")))
    #expect(try #require(AppVersion("1.0.0")) > #require(AppVersion("0.9.9")))
  }

  @Test func aTagNeedsItsV() {
    #expect(AppVersion(tag: "0.1.2") == nil)
    #expect(AppVersion(tag: "v0.1.2")?.tag == "v0.1.2")
    #expect(AppVersion(tag: "v0.1.2-rc1") == nil)
  }

  @Test func aVersionIsStoredAsOneString() throws {
    let version = try #require(AppVersion("0.1.2"))
    #expect(String(decoding: try JSONEncoder().encode([version]), as: UTF8.self) == #"["0.1.2"]"#)
    #expect(
      try JSONDecoder().decode([AppVersion].self, from: Data(#"["0.1.2"]"#.utf8)) == [version])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([AppVersion].self, from: Data(#"["0.1"]"#.utf8))
    }
  }

  @Test func aReplyGivesTheVersionAndBuiltURLs() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "release-latest", withExtension: "json", subdirectory: "Fixtures"))
    let release = try Release.parse(Data(contentsOf: url))
    #expect(release.version == AppVersion("0.1.3"))
    #expect(
      release.imageURL.absoluteString
        == "https://github.com/getLiveBridge/LiveBridge/releases/download/v0.1.3/LiveBridge.dmg")
    #expect(
      release.pageURL.absoluteString
        == "https://github.com/getLiveBridge/LiveBridge/releases/tag/v0.1.3")
  }

  @Test func aSuffixedTagIsRefused() {
    let reply = Data(#"{"tag_name":"v0.2.0-rc1","assets":[{"name":"LiveBridge.dmg"}]}"#.utf8)
    #expect(throws: UpdateProblem.badTag("v0.2.0-rc1")) { try Release.parse(reply) }
  }

  @Test func aReleaseWithoutTheImageIsRefused() {
    let reply = Data(#"{"tag_name":"v0.2.0","assets":[{"name":"notes.txt"}]}"#.utf8)
    #expect(throws: UpdateProblem.noImage) { try Release.parse(reply) }
    #expect(throws: UpdateProblem.noImage) {
      try Release.parse(Data(#"{"tag_name":"v0.2.0"}"#.utf8))
    }
    // The attestation the release carries next to the image is not the image.
    let bundleOnly = Data(
      #"{"tag_name":"v0.2.0","assets":[{"name":"LiveBridge.dmg.sigstore.json"}]}"#.utf8)
    #expect(throws: UpdateProblem.noImage) { try Release.parse(bundleOnly) }
  }

  @Test func aReplyThatIsNotJSONIsRefused() {
    #expect {
      try Release.parse(Data("<html>rate limited</html>".utf8))
    } throws: { error in
      guard case .network = error as? UpdateProblem else { return false }
      return true
    }
  }

  @Test func theRepositoryPageIsTheRepositorysGitHubURL() {
    #expect(Release.repositoryPage.absoluteString == "https://github.com/getLiveBridge/LiveBridge")
  }

  @Test func theBugFormIsTheBugTemplate() {
    #expect(
      Release.bugReportForm.absoluteString
        == "https://github.com/getLiveBridge/LiveBridge/issues/new?template=bug_report.yml")
  }
}
