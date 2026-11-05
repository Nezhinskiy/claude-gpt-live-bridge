import AppKit
import BridgeCore
import Observation
import SwiftUI

/// The menu bar item and its menu: an `NSStatusItem` whose button shows the animated glyph, and
/// a real `NSMenu`, so its corners, material and shadow are the system's own. `MenuContent`
/// says what it holds; this renders it: the call card, the session rows and the conversation
/// are hosted SwiftUI views (`MenuRows.swift`), the rest native items. The menu follows
/// the model while it is open: items are updated in place, and rebuilt only when the content's
/// shape changes; hosted views keep their state across updates.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
  /// The menu's width; every custom row fills it.
  static let width: CGFloat = 320
  /// The tallest the conversation's item grows; past it, it scrolls.
  static let conversationHeight: CGFloat = 360

  private let model: AppModel
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  let highlight = MenuHighlight()
  private var rendered: MenuContent?
  /// Native items and submenus, by a key stable across updates (`key(of:)`).
  private var natives: [String: NSMenuItem] = [:]
  private var submenus: [String: NSMenu] = [:]
  private var card: HostedItem<CallCardView>?
  private var rows: [SessionID: HostedItem<SessionRowView>] = [:]
  private var transcript: ScrollingItem<TranscriptView>?
  private var sent: HostedItem<SentView>?
  /// What a hosted session row's item is, for the menu's highlight.
  private var rowKeys: [ObjectIdentifier: String] = [:]
  /// Actions that wait until the menu has closed and its tracking has ended, as an alert does.
  private var afterClose: [() -> Void] = []
  private var pending: [() -> Void] = []

  init(model: AppModel) {
    self.model = model
    super.init()
    configure(menu)
    menu.minimumWidth = Self.width
    item.menu = menu
    item.button?.imagePosition = .imageOnly
    showGlyph()
    observe()
  }

  /// Opens the menu, as a click on a notification does.
  func open() { item.button?.performClick(nil) }

  // MARK: - Actions the rows ask for

  func perform(_ action: CallAction) { model.perform(action) }
  func setTarget(_ id: SessionID) { model.setTarget(id) }

  /// Closes the menu, then does `action` once its tracking has ended: an alert, a window, or
  /// another app.
  func closeThen(_ action: @escaping () -> Void) {
    afterClose.append(action)
    menu.cancelTracking()
  }

  /// The × asks first, with the menu closed.
  func remove(_ row: SessionRowPresentation) {
    closeThen { [model] in model.remove(row) }
  }

  // MARK: - Rendering

  /// What the model says the menu holds now.
  private var content: MenuContent {
    MenuContent(
      update: model.update, problem: model.problem, contextLoad: model.contextLoad,
      available: model.available?.version)
  }

  /// Renders the model's current content, and again whenever it changes. Only the content is
  /// read under observation; the hosted views are given what they show.
  private func observe() {
    let now = withObservationTracking {
      content
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    show(now)
  }

  private func show(_ content: MenuContent) {
    guard content != rendered else { return }
    rendered = content
    var used = Set<String>()
    fill(menu, path: "", with: content.items, used: &used)
    natives = natives.filter { used.contains($0.key) }
    submenus = submenus.filter { used.contains($0.key) }
    rows = rows.filter { used.contains("row|\($0.key.rawValue)") }
    if !used.contains("transcript") { transcript = nil }
    if !used.contains("sent") { sent = nil }
    rowKeys = Dictionary(
      uniqueKeysWithValues: rows.map { (ObjectIdentifier($0.value.item), "row|\($0.key.rawValue)") }
    )
  }

  private func fill(
    _ menu: NSMenu, path: String, with entries: [MenuContent.Item], used: inout Set<String>
  ) {
    var separators = 0
    var notes = 0
    let built = entries.map { entry -> NSMenuItem in
      switch entry {
      case .call(let shown):
        used.insert("call")
        let view = CallCardView(card: shown, glyph: model.glyph, menu: self)
        let hosted = card ?? HostedItem(view)
        hosted.show(view)
        card = hosted
        return hosted.item

      case .separator:
        separators += 1
        return native("\(path)|---\(separators)", used: &used) { .separator() }

      case .header(let title):
        return native("\(path)|# \(title)", used: &used) { .sectionHeader(title: title) }

      case .note(let text):
        notes += 1
        let item = native("\(path)|note\(notes)", used: &used) { NSMenuItem() }
        item.title = text
        item.isEnabled = false
        return item

      case .command(let command, let title, let isEnabled):
        let item = native("cmd|\(command)", used: &used) { self.commandItem(command) }
        item.title = title
        item.isEnabled = isEnabled
        return item

      case .submenu(let title, let isEnabled, let items):
        let key = "sub|\(title)"
        let item = native(key, used: &used) {
          NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }
        item.isEnabled = isEnabled
        if items.isEmpty {
          item.submenu = nil
        } else {
          let submenu = submenus[key] ?? configure(NSMenu(title: title))
          submenus[key] = submenu
          fill(submenu, path: key, with: items, used: &used)
          if item.submenu !== submenu { item.submenu = submenu }
        }
        return item

      case .session(let shown):
        let key = "row|\(shown.id.rawValue)"
        used.insert(key)
        let view = SessionRowView(row: shown, key: key, menu: self)
        let row = rows[shown.id] ?? HostedItem(view)
        row.show(view)
        rows[shown.id] = row
        return row.item

      case .transcript(let lines):
        used.insert("transcript")
        let view = TranscriptView(lines: lines)
        let shown =
          transcript ?? ScrollingItem(view, maxHeight: Self.conversationHeight)
        if transcript != nil { shown.show(view) }
        transcript = shown
        return shown.item

      case .sent(let text):
        used.insert("sent")
        let row = sent ?? HostedItem(SentView(text: text), enabled: false)
        row.show(SentView(text: text))
        sent = row
        return row.item
      }
    }
    sync(menu, built)
  }

  /// Puts `items` in `menu`, in order, unless it holds exactly them already. An item stands in
  /// one menu only, so one moving between the menu and a submenu leaves the other first.
  private func sync(_ menu: NSMenu, _ items: [NSMenuItem]) {
    guard menu.items.count != items.count || !zip(menu.items, items).allSatisfy(===) else {
      return
    }
    menu.removeAllItems()
    for item in items {
      item.menu?.removeItem(item)
      menu.addItem(item)
    }
  }

  private func native(
    _ key: String, used: inout Set<String>, make: () -> NSMenuItem
  ) -> NSMenuItem {
    used.insert(key)
    if let item = natives[key] { return item }
    let item = make()
    natives[key] = item
    return item
  }

  private func commandItem(_ command: MenuContent.Command) -> NSMenuItem {
    let action: Selector =
      switch command {
      case .copyJoinCommand: #selector(copyJoinCommand)
      case .loadContext: #selector(loadContext)
      case .newConversation: #selector(newConversation)
      case .starOnGitHub: #selector(starOnGitHub)
      case .settings: #selector(showSettings)
      case .quit: #selector(quit)
      case .installUpdate: #selector(installUpdate(_:))
      }
    let item = NSMenuItem(title: "", action: action, keyEquivalent: command.keyEquivalent)
    item.target = self
    if case .installUpdate(let version) = command { item.representedObject = version }
    return item
  }

  @discardableResult private func configure(_ menu: NSMenu) -> NSMenu {
    menu.delegate = self
    menu.autoenablesItems = false  // the content says which items are enabled
    menu.showsStateColumn = false  // no item has a state, so titles start where the rows' do
    return menu
  }

  // MARK: - Native items

  /// The menu has closed by then: a native item's action is sent after its tracking.
  @objc private func copyJoinCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(StatusPresentation.joinCommand, forType: .string)
  }

  @objc private func loadContext() { model.loadContext() }

  @objc private func newConversation() { later { [model] in model.newConversation() } }

  @objc private func showSettings() { later { [model] in model.showSettings() } }

  @objc private func starOnGitHub() { NSWorkspace.shared.open(Release.repositoryPage) }

  @objc private func quit() { NSApp.terminate(nil) }

  /// Installs the item's version as a notice's Install does: Settings opens on the update
  /// section's progress, past any confirmation the install asks.
  @objc private func installUpdate(_ sender: NSMenuItem) {
    guard let version = sender.representedObject as? AppVersion else { return }
    later { [model] in model.installUpdate(version) }
  }

  /// Runs `action` once the run loop is back in its default mode, past any menu tracking.
  private func later(_ action: @escaping () -> Void) {
    pending.append(action)
    RunLoop.main.perform(inModes: [.default]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.pending.isEmpty else { return }
        self.pending.removeFirst()()
      }
    }
  }

  // MARK: - NSMenuDelegate

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === self.menu else { return }
    show(content)
  }

  /// A custom row draws the highlight the menu gives it, by mouse or by keyboard.
  func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
    highlight.set(item.flatMap { rowKeys[ObjectIdentifier($0)] }, in: menu)
  }

  func menuDidClose(_ menu: NSMenu) {
    highlight.set(nil, in: menu)
    guard menu === self.menu else { return }
    highlight.clear()
    let actions = afterClose
    afterClose = []
    actions.forEach(later)
  }

  // MARK: - The glyph

  /// The button shows the glyph's current frame and the call's accessibility label.
  private func showGlyph() {
    withObservationTracking {
      item.button?.image = model.glyph.image
      item.button?.setAccessibilityLabel(model.presentation?.accessibilityLabel ?? "LiveBridge")
    } onChange: { [weak self] in
      Task { @MainActor in self?.showGlyph() }
    }
  }
}

/// Which custom rows the menu and its submenus highlight: one item per open menu at most.
@MainActor @Observable
final class MenuHighlight {
  private var byMenu: [ObjectIdentifier: String] = [:]

  func set(_ key: String?, in menu: NSMenu) {
    let id = ObjectIdentifier(menu)
    if byMenu[id] != key { byMenu[id] = key }
  }

  func clear() { if !byMenu.isEmpty { byMenu = [:] } }

  func contains(_ key: String) -> Bool { byMenu.values.contains(key) }
}

/// A menu item whose view is a hosted SwiftUI view, `StatusMenu.width` wide and as tall as the
/// view wants: its height is measured when it is made and followed as the view changes (a
/// banner opening, a line wrapping), and the open menu resizes with it.
@MainActor
final class HostedItem<Content: View> {
  let item = NSMenuItem()
  let host: NSHostingView<Fitted<Content>>
  private let fit = Fit()
  /// Told after the host took a new height, for a view around it (`ScrollingItem`).
  var resized: () -> Void = {}

  init(_ content: Content, enabled: Bool = true) {
    host = NSHostingView(rootView: Fitted(content: content, fit: fit))
    fit.resize = { [weak self] in self?.fit(height: $0) }
    fit(height: max(host.fittingSize.height, 1))
    item.view = host
    item.isEnabled = enabled
  }

  /// The new content; the view's own state (an open help, a "Copied") is kept.
  func show(_ content: Content) { host.rootView = Fitted(content: content, fit: fit) }

  private func fit(height: CGFloat) {
    guard height > 0, abs(host.frame.height - height) > 0.5 else { return }
    host.setFrameSize(NSSize(width: StatusMenu.width, height: height))
    resized()
  }
}

@MainActor
final class Fit {
  var resize: (CGFloat) -> Void = { _ in }
}

/// A row's content at the menu's width and its own height, reporting that height.
struct Fitted<Content: View>: View {
  let content: Content
  let fit: Fit

  var body: some View {
    content
      .frame(width: StatusMenu.width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        fit.resize($0)
      }
  }
}
