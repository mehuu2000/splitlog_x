import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private weak var mainWindow: NSWindow?
  private var outsideClickLocalMonitor: Any?
  private var outsideClickGlobalMonitor: Any?
  private var isPopoverLocked = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async {
      self.configureStatusItem()
      self.configureMainWindow()
      self.showMainWindow()
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideMainWindow()
    return false
  }

  private func configureStatusItem() {
    let statusItem = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.statusItem = statusItem
    statusItem.autosaveName = "SplitLogStatusItem"

    guard let button = statusItem.button else {
      return
    }
    statusItem.length = NSStatusItem.squareLength
    button.image = makeStatusIcon()
    button.imagePosition = .imageOnly
    button.toolTip = "SplitLog"
    button.target = self
    button.action = #selector(handleStatusItemClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  private func configureMainWindow() {
    let window = NSApp.windows.first { $0 is MainFlutterWindow } ?? NSApp.windows.first
    mainWindow = window
    window?.delegate = self
  }

  private func makeStatusIcon() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()

    NSColor.black.setStroke()

    let body = NSBezierPath(ovalIn: NSRect(x: 3.2, y: 2.4, width: 11.8, height: 11.8))
    body.lineWidth = 1.8
    body.stroke()

    let crown = NSBezierPath()
    crown.lineWidth = 1.8
    crown.move(to: NSPoint(x: 9.1, y: 14.1))
    crown.line(to: NSPoint(x: 9.1, y: 16.2))
    crown.stroke()

    let sideButton = NSBezierPath()
    sideButton.lineWidth = 1.5
    sideButton.move(to: NSPoint(x: 13.4, y: 13.2))
    sideButton.line(to: NSPoint(x: 15.0, y: 14.7))
    sideButton.stroke()

    let hand = NSBezierPath()
    hand.lineWidth = 1.6
    hand.lineCapStyle = .round
    hand.move(to: NSPoint(x: 9.1, y: 8.3))
    hand.line(to: NSPoint(x: 9.1, y: 12.0))
    hand.move(to: NSPoint(x: 9.1, y: 8.3))
    hand.line(to: NSPoint(x: 11.4, y: 8.3))
    hand.stroke()

    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  @objc
  private func handleStatusItemClick(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showStatusMenu(relativeTo: sender)
      return
    }

    toggleMainWindow()
  }

  @objc
  private func showMainWindowFromMenu() {
    showMainWindow()
  }

  @objc
  private func hideMainWindowFromMenu() {
    hideMainWindow()
  }

  @objc
  private func quitAppFromMenu() {
    NSApp.terminate(nil)
  }

  func toggleMainWindow() {
    if let window = mainWindow, window.isVisible {
      hideMainWindow()
      return
    }

    showMainWindow()
  }

  func showMainWindow() {
    if mainWindow == nil {
      configureMainWindow()
    }
    guard let window = mainWindow else {
      return
    }

    positionMainWindowNearStatusItem(window)
    NSApp.activate(ignoringOtherApps: true)
    window.level = isPopoverLocked ? .floating : .normal
    window.makeKeyAndOrderFront(nil)
    if isPopoverLocked {
      window.orderFrontRegardless()
    }
    installOutsideClickMonitors()
  }

  func hideMainWindow() {
    removeOutsideClickMonitors()
    mainWindow?.orderOut(nil)
  }

  func setPopoverLocked(_ isLocked: Bool) {
    isPopoverLocked = isLocked
    mainWindow?.level = isLocked ? .floating : .normal
    if isLocked, let mainWindow, mainWindow.isVisible {
      mainWindow.orderFrontRegardless()
    }
  }

  private func showStatusMenu(relativeTo button: NSStatusBarButton) {
    let menu = NSMenu()
    let isVisible = mainWindow?.isVisible == true
    let visibilityItem = NSMenuItem(
      title: isVisible ? "SplitLogを非表示" : "SplitLogを表示",
      action: isVisible ? #selector(hideMainWindowFromMenu) : #selector(showMainWindowFromMenu),
      keyEquivalent: ""
    )
    visibilityItem.target = self
    menu.addItem(visibilityItem)
    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "SplitLogを終了",
      action: #selector(quitAppFromMenu),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
  }

  private func positionMainWindowNearStatusItem(_ window: NSWindow) {
    guard
      let button = statusItem?.button,
      let buttonWindow = button.window,
      let screen = buttonWindow.screen ?? NSScreen.main
    else {
      window.center()
      return
    }

    let buttonFrameInWindow = button.convert(button.bounds, to: nil)
    let buttonFrame = buttonWindow.convertToScreen(buttonFrameInWindow)
    let visibleFrame = screen.visibleFrame
    let windowSize = window.frame.size
    let horizontalMargin = 8.0
    let verticalMargin = 8.0
    let proposedX = buttonFrame.midX - (windowSize.width / 2)
    let x = min(
      max(proposedX, visibleFrame.minX + horizontalMargin),
      visibleFrame.maxX - windowSize.width - horizontalMargin
    )
    let y = visibleFrame.maxY - windowSize.height - verticalMargin

    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  private func installOutsideClickMonitors() {
    guard outsideClickLocalMonitor == nil, outsideClickGlobalMonitor == nil else {
      return
    }

    outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self, self.mainWindow?.isVisible == true, !self.isPopoverLocked else {
        return event
      }
      guard !self.isEventInsideMainWindow(event), !self.isEventOnStatusItemButton(event) else {
        return event
      }

      self.hideMainWindow()
      return event
    }

    outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.mainWindow?.isVisible == true, !self.isPopoverLocked else {
          return
        }

        self.hideMainWindow()
      }
    }
  }

  private func removeOutsideClickMonitors() {
    if let outsideClickLocalMonitor {
      NSEvent.removeMonitor(outsideClickLocalMonitor)
      self.outsideClickLocalMonitor = nil
    }

    if let outsideClickGlobalMonitor {
      NSEvent.removeMonitor(outsideClickGlobalMonitor)
      self.outsideClickGlobalMonitor = nil
    }
  }

  private func isEventInsideMainWindow(_ event: NSEvent) -> Bool {
    guard let mainWindow else {
      return false
    }

    return event.window === mainWindow
  }

  private func isEventOnStatusItemButton(_ event: NSEvent) -> Bool {
    guard
      let button = statusItem?.button,
      let buttonWindow = button.window,
      event.window === buttonWindow
    else {
      return false
    }

    let location = button.convert(event.locationInWindow, from: nil)
    return button.bounds.contains(location)
  }
}
