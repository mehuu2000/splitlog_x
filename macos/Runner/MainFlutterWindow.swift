import Cocoa
import Carbon
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private struct ShortcutPayload {
    let action: String
    let index: Int?
    let offset: Int?
  }

  private static let hotKeySignature = OSType(0x53504C47)

  private var appChannel: FlutterMethodChannel?
  private var eventHandler: EventHandlerRef?
  private var registeredHotKeys: [EventHotKeyRef] = []
  private var hotKeyPayloads: [UInt32: ShortcutPayload] = [:]
  private var nextHotKeyID: UInt32 = 1

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let contentSize = NSSize(width: 540, height: 380)
    styleMask.insert(.fullSizeContentView)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    minSize = contentSize
    maxSize = contentSize
    setContentSize(contentSize)
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureAppChannel(flutterViewController)

    super.awakeFromNib()
  }

  private func configureAppChannel(_ flutterViewController: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "splitlog_x/app",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "quitApp":
        NSApp.terminate(nil)
        result(nil)
      case "setShortcutsEnabled":
        let arguments = call.arguments as? [String: Any]
        let enabled = arguments?["enabled"] as? Bool ?? true
        self.setShortcutsEnabled(enabled)
        result(nil)
      case "setPopoverLocked":
        let arguments = call.arguments as? [String: Any]
        let isLocked = arguments?["locked"] as? Bool ?? false
        (NSApp.delegate as? AppDelegate)?.setPopoverLocked(isLocked)
        result(nil)
      case "chooseLegacyFile":
        self.chooseLegacyFile(result: result)
      case "openContact":
        self.openContactMail()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    appChannel = channel
  }

  private func setShortcutsEnabled(_ enabled: Bool) {
    if enabled {
      configureHotKeys()
    } else {
      unregisterHotKeys()
    }
  }

  private func configureHotKeys() {
    guard registeredHotKeys.isEmpty else {
      return
    }

    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else {
          return noErr
        }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        guard status == noErr else {
          return status
        }
        let window = Unmanaged<MainFlutterWindow>
          .fromOpaque(userData)
          .takeUnretainedValue()
        window.handleHotKey(withID: hotKeyID.id)
        return noErr
      },
      1,
      &eventSpec,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )

    let modifiers = UInt32(cmdKey | controlKey)
    registerHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers, payload: ShortcutPayload(action: "split", index: nil, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: modifiers, payload: ShortcutPayload(action: "stop", index: nil, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers, payload: ShortcutPayload(action: "resume", index: nil, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: modifiers, payload: ShortcutPayload(action: "togglePopover", index: nil, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: modifiers, payload: ShortcutPayload(action: "memo", index: nil, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 1, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 2, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 3, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 4, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_5), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 5, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_6), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 6, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_7), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 7, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_8), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 8, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_9), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 9, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_ANSI_0), modifiers: modifiers, payload: ShortcutPayload(action: "targetLap", index: 0, offset: nil))
    registerHotKey(keyCode: UInt32(kVK_UpArrow), modifiers: modifiers, payload: ShortcutPayload(action: "moveLap", index: nil, offset: -1))
    registerHotKey(keyCode: UInt32(kVK_DownArrow), modifiers: modifiers, payload: ShortcutPayload(action: "moveLap", index: nil, offset: 1))
  }

  private func unregisterHotKeys() {
    for hotKey in registeredHotKeys {
      UnregisterEventHotKey(hotKey)
    }
    registeredHotKeys.removeAll()
    hotKeyPayloads.removeAll()
    nextHotKeyID = 1

    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  private func registerHotKey(keyCode: UInt32, modifiers: UInt32, payload: ShortcutPayload) {
    var hotKeyRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: nextHotKeyID)
    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    guard status == noErr, let hotKeyRef else {
      nextHotKeyID += 1
      return
    }
    registeredHotKeys.append(hotKeyRef)
    hotKeyPayloads[nextHotKeyID] = payload
    nextHotKeyID += 1
  }

  private func handleHotKey(withID id: UInt32) {
    guard let payload = hotKeyPayloads[id] else {
      return
    }

    if payload.action == "togglePopover" {
      (NSApp.delegate as? AppDelegate)?.toggleMainWindow()
      return
    }

    (NSApp.delegate as? AppDelegate)?.showMainWindow()
    var arguments: [String: Any] = ["action": payload.action]
    if let index = payload.index {
      arguments["index"] = index
    }
    if let offset = payload.offset {
      arguments["offset"] = offset
    }
    appChannel?.invokeMethod("shortcutAction", arguments: arguments)
  }

  private func chooseLegacyFile(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.title = "旧SplitLogのsessions.jsonを選択"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedFileTypes = ["json"]

    NSApp.activate(ignoringOtherApps: true)
    panel.level = .floating
    let response = panel.runModal()
    guard response == .OK, let url = panel.url else {
      result(nil)
      return
    }
    do {
      result(try String(contentsOf: url, encoding: .utf8))
    } catch {
      result(FlutterError(code: "read_failed", message: "sessions.jsonを読み込めませんでした。", details: nil))
    }
  }

  private func openContactMail() {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = "hamachii.project@proton.me"
    components.queryItems = [
      URLQueryItem(name: "subject", value: "SplitLog お問い合わせ"),
      URLQueryItem(
        name: "body",
        value: """
SplitLog version:
macOS version:
お問い合わせ種別:
内容:
"""
      )
    ]

    if let url = components.url {
      NSWorkspace.shared.open(url)
    }
  }
}
