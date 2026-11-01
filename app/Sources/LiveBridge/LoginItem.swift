import ServiceManagement

/// "Open at login": the app itself as a login item, registered only when the owner turns it on.
enum LoginItem {
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  static func set(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
