import Foundation
import Testing

@testable import BridgeCore

struct UpdatePolicyTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func aCheckIsDueAfterADay() {
    let last = now.addingTimeInterval(-86_400)
    #expect(UpdatePolicy.isCheckDue(now: now, lastCheck: last, enabled: true))
  }

  @Test func aCheckIsNotDueWithinADay() {
    let last = now.addingTimeInterval(-86_399)
    #expect(!UpdatePolicy.isCheckDue(now: now, lastCheck: last, enabled: true))
  }

  @Test func aCheckIsDueWhenTheClockMovedBack() {
    let last = now.addingTimeInterval(60)
    #expect(UpdatePolicy.isCheckDue(now: now, lastCheck: last, enabled: true))
  }

  @Test func aCheckIsDueWhenNeverChecked() {
    #expect(UpdatePolicy.isCheckDue(now: now, lastCheck: nil, enabled: true))
  }

  @Test func noCheckWithTheToggleOff() {
    #expect(!UpdatePolicy.isCheckDue(now: now, lastCheck: nil, enabled: false))
    let last = now.addingTimeInterval(-200_000)
    #expect(!UpdatePolicy.isCheckDue(now: now, lastCheck: last, enabled: false))
  }

  @Test func aSourceBuildDefaultsChecksOff() {
    #expect(!UpdatePolicy.checksAutomatically(setting: nil, isSourceBuild: true))
    #expect(UpdatePolicy.checksAutomatically(setting: nil, isSourceBuild: false))
    #expect(UpdatePolicy.checksAutomatically(setting: true, isSourceBuild: true))
    #expect(!UpdatePolicy.checksAutomatically(setting: false, isSourceBuild: false))
  }

  @Test func onlyTheApplicationsCopyIsInstalled() {
    #expect(
      UpdatePolicy.isInstalledCopy(
        resolvedBundlePath: "/Applications/LiveBridge.app", installedPathIsSymlink: false))
    #expect(
      !UpdatePolicy.isInstalledCopy(
        resolvedBundlePath: "/Users/example/Applications/LiveBridge.app",
        installedPathIsSymlink: false))
    #expect(
      !UpdatePolicy.isInstalledCopy(
        resolvedBundlePath: "/Applications/LiveBridge.app", installedPathIsSymlink: true))
  }

  @Test func theAppsUpdatePathsInstallTheInstalledCopy() {
    let paths = UpdatePaths(dataDir: URL(filePath: "/Users/example/Library/LiveBridge"))
    #expect(paths.installed.path == "/Applications/LiveBridge.app")
    #expect(paths.updates.path == "/Users/example/Library/LiveBridge/updates")
  }
}

struct UpdateStateTests {
  @Test func theCheckStateSurvivesARestart() throws {
    let file = try temporaryDirectory().appending(path: "updates/state.json")
    let checked = Date(timeIntervalSince1970: 1_800_000_000)
    let version = try #require(AppVersion("0.1.3"))
    UpdateStateStore(file: file).update {
      $0.lastCheck = checked
      $0.announced.insert(version)
    }
    let reread = UpdateStateStore(file: file).current
    #expect(reread == UpdateState(lastCheck: checked, announced: [version]))
  }

  @Test func anUnreadableStateIsEmpty() throws {
    let dir = try temporaryDirectory()
    #expect(UpdateStateStore(file: dir.appending(path: "missing.json")).current == UpdateState())
    let file = dir.appending(path: "state.json")
    try Data("not json".utf8).write(to: file)
    #expect(UpdateStateStore(file: file).current == UpdateState())
  }
}
