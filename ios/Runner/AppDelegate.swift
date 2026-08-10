import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  UIDocumentPickerDelegate
{
  private var appChannel: FlutterMethodChannel?
  private var pendingFilePickerResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "splitlog_x/app",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "chooseLegacyFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.showLegacyFilePicker(result: result)
    }
    appChannel = channel
  }

  private func showLegacyFilePicker(result: @escaping FlutterResult) {
    guard pendingFilePickerResult == nil else {
      result(
        FlutterError(
          code: "file_picker_busy",
          message: "A document picker is already open.",
          details: nil
        )
      )
      return
    }

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [UTType.json],
        asCopy: true
      )
    } else {
      picker = UIDocumentPickerViewController(
        documentTypes: ["public.json"],
        in: .import
      )
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false

    guard let presenter = activeViewController() else {
      result(
        FlutterError(
          code: "file_picker_unavailable",
          message: "Unable to present the document picker.",
          details: nil
        )
      )
      return
    }
    pendingFilePickerResult = result
    presenter.present(picker, animated: true)
  }

  private func activeViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishFilePicker(with: nil)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let url = urls.first else {
      finishFilePicker(with: nil)
      return
    }
    let isAccessing = url.startAccessingSecurityScopedResource()
    defer {
      if isAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    do {
      finishFilePicker(with: try String(contentsOf: url, encoding: .utf8))
    } catch {
      finishFilePicker(
        with: FlutterError(
          code: "file_read_failed",
          message: "Unable to read the selected sessions.json file.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func finishFilePicker(with value: Any?) {
    let result = pendingFilePickerResult
    pendingFilePickerResult = nil
    result?(value)
  }
}
