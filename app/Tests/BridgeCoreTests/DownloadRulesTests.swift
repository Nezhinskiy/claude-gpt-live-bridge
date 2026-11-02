import Foundation
import Testing

@testable import BridgeCore

/// The limits on what the update download follows and keeps (the spec's step 2).
struct DownloadRulesTests {
  @Test func aRedirectToAnotherHostIsRefused() throws {
    for text in [
      "https://example.com/LiveBridge.dmg", "https://github.com.example.com/LiveBridge.dmg",
      "https://evilgithub.com/LiveBridge.dmg", "https://githubusercontent.com/LiveBridge.dmg",
    ] {
      let url = try #require(URL(string: text))
      #expect(!DownloadRules.allowsRedirect(to: url, hosts: DownloadRules.assetHosts), "\(text)")
    }
  }

  @Test func aRedirectOverHTTPIsRefused() throws {
    let url = try #require(URL(string: "http://objects.githubusercontent.com/LiveBridge.dmg"))
    #expect(!DownloadRules.allowsRedirect(to: url, hosts: DownloadRules.assetHosts))
  }

  @Test func aRedirectToAnotherPortIsRefused() throws {
    let url = try #require(URL(string: "https://github.com:8443/LiveBridge.dmg"))
    #expect(!DownloadRules.allowsRedirect(to: url, hosts: DownloadRules.assetHosts))
  }

  @Test func aRedirectToTheAssetHostIsAllowed() throws {
    let hosts = [
      "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]
    for host in hosts {
      let url = try #require(URL(string: "https://\(host)/example/LiveBridge.dmg?sig=1"))
      #expect(DownloadRules.allowsRedirect(to: url, hosts: DownloadRules.assetHosts), "\(host)")
    }
  }

  /// The API check follows a redirect only within `api.github.com`.
  @Test func anAPIRedirectStaysOnTheAPIHost() throws {
    let api = try #require(URL(string: "https://api.github.com/repositories/1/releases/latest"))
    let asset = try #require(URL(string: "https://github.com/example/releases/latest"))
    #expect(DownloadRules.allowsRedirect(to: api, hosts: DownloadRules.apiHosts))
    #expect(!DownloadRules.allowsRedirect(to: asset, hosts: DownloadRules.apiHosts))
  }

  @Test func aDeclaredLengthOverTheCapIsRefused() {
    #expect(DownloadRules.exceeds(maxBytes: 100, declared: 101, received: 0))
    #expect(!DownloadRules.exceeds(maxBytes: 100, declared: 100, received: 0))
    #expect(!DownloadRules.exceeds(maxBytes: 100, declared: -1, received: 0))
  }

  @Test func receivedBytesOverTheCapAreRefused() {
    #expect(DownloadRules.exceeds(maxBytes: 100, declared: -1, received: 101))
    #expect(!DownloadRules.exceeds(maxBytes: 100, declared: 50, received: 100))
  }
}
