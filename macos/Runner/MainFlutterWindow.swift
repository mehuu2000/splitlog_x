import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appChannel: FlutterMethodChannel?

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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    appChannel = channel
  }
}
