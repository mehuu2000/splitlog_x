#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <windows.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct ShortcutPayload {
    std::string action;
    std::optional<int> index;
    std::optional<int> offset;
  };

  void ConfigurePopupWindow();
  void ConfigurePlatformChannel();
  void HandlePlatformCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void PositionWindowNearTrayIcon();
  void ShowMainWindow();
  void HideMainWindow();
  void ToggleMainWindow();
  void SetPopoverLocked(bool locked);

  void SetShortcutsEnabled(bool enabled);
  void RegisterShortcut(UINT virtual_key, ShortcutPayload payload);
  void UnregisterShortcuts();
  void HandleShortcut(int id);

  void ChooseLegacyFile(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void OpenContact(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void RequestQuit();
  void QuitNow();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> app_channel_;

  NOTIFYICONDATAW tray_icon_{};
  bool tray_icon_added_ = false;
  bool popover_locked_ = false;
  bool suppress_auto_hide_ = false;
  bool quit_request_pending_ = false;
  bool quitting_ = false;
  UINT taskbar_created_message_ = 0;
  int next_shortcut_id_ = 1;
  std::map<int, ShortcutPayload> shortcut_payloads_;
  std::vector<int> registered_shortcut_ids_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
