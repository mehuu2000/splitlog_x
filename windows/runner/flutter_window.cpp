#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/method_result_functions.h>
#include <commdlg.h>
#include <shellapi.h>
#include <windowsx.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "window_messages.h"

namespace {

constexpr UINT kTrayIconMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayMenuToggle = 100;
constexpr UINT kTrayMenuQuit = 101;
constexpr UINT kShortcutModifiers = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
constexpr UINT_PTR kAutoHideTimerId = 1;
constexpr UINT kAutoHideDelayMilliseconds = 80;
constexpr int kPopupMargin = 8;

const flutter::EncodableMap* GetArguments(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

bool GetBoolArgument(const flutter::EncodableMap* arguments,
                     const char* key,
                     bool fallback) {
  if (arguments == nullptr) {
    return fallback;
  }
  const auto iterator = arguments->find(flutter::EncodableValue(key));
  if (iterator == arguments->end()) {
    return fallback;
  }
  const auto* value = std::get_if<bool>(&iterator->second);
  return value == nullptr ? fallback : *value;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  ConfigurePopupWindow();
  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  ConfigurePlatformChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    ShowMainWindow();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UnregisterShortcuts();
  RemoveTrayIcon();
  if (app_channel_) {
    app_channel_->SetMethodCallHandler(nullptr);
    app_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == taskbar_created_message_) {
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case kSplitLogShowWindowMessage:
      ShowMainWindow();
      return 0;
    case WM_CLOSE:
      if (!quitting_) {
        HideMainWindow();
        return 0;
      }
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        if (!popover_locked_ && !suppress_auto_hide_ &&
            IsWindowVisible(hwnd)) {
          SetTimer(hwnd, kAutoHideTimerId, kAutoHideDelayMilliseconds, nullptr);
        }
      } else {
        KillTimer(hwnd, kAutoHideTimerId);
      }
      break;
    case WM_TIMER:
      if (wparam == kAutoHideTimerId) {
        KillTimer(hwnd, kAutoHideTimerId);
        if (!popover_locked_ && !suppress_auto_hide_ &&
            IsWindowVisible(hwnd) && GetForegroundWindow() != hwnd) {
          HideMainWindow();
        }
        return 0;
      }
      break;
    case WM_HOTKEY:
      HandleShortcut(static_cast<int>(wparam));
      return 0;
    case WM_COMMAND:
      if (LOWORD(wparam) == kTrayMenuToggle) {
        ToggleMainWindow();
        return 0;
      }
      if (LOWORD(wparam) == kTrayMenuQuit) {
        RequestQuit();
        return 0;
      }
      break;
    case kTrayIconMessage:
      KillTimer(hwnd, kAutoHideTimerId);
      if (lparam == WM_LBUTTONUP || lparam == NIN_SELECT ||
          lparam == NIN_KEYSELECT) {
        ToggleMainWindow();
        return 0;
      }
      if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
        ShowTrayMenu();
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ConfigurePopupWindow() {
  const HWND window = GetHandle();
  LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
             WS_SYSMENU);
  style |= WS_POPUP;
  SetWindowLongPtr(window, GWL_STYLE, style);

  LONG_PTR extended_style = GetWindowLongPtr(window, GWL_EXSTYLE);
  extended_style &= ~WS_EX_APPWINDOW;
  extended_style |= WS_EX_TOOLWINDOW;
  SetWindowLongPtr(window, GWL_EXSTYLE, extended_style);

  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

  const DWM_WINDOW_CORNER_PREFERENCE corner_preference = DWMWCP_ROUND;
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));
}

void FlutterWindow::ConfigurePlatformChannel() {
  app_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "splitlog_x/app",
          &flutter::StandardMethodCodec::GetInstance());
  app_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandlePlatformCall(call, std::move(result));
      });
}

void FlutterWindow::HandlePlatformCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "quitApp") {
    result->Success();
    QuitNow();
    return;
  }
  if (call.method_name() == "setShortcutsEnabled") {
    SetShortcutsEnabled(
        GetBoolArgument(GetArguments(call), "enabled", true));
    result->Success();
    return;
  }
  if (call.method_name() == "setPopoverLocked") {
    SetPopoverLocked(GetBoolArgument(GetArguments(call), "locked", false));
    result->Success();
    return;
  }
  if (call.method_name() == "chooseLegacyFile") {
    ChooseLegacyFile(std::move(result));
    return;
  }
  if (call.method_name() == "openContact") {
    OpenContact(std::move(result));
    return;
  }
  result->NotImplemented();
}

bool FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_ || GetHandle() == nullptr) {
    return tray_icon_added_;
  }

  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayIconMessage;
  tray_icon_.hIcon = LoadIconW(GetModuleHandle(nullptr),
                               MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"SplitLog");

  tray_icon_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  return tray_icon_added_;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  const bool visible = IsWindowVisible(GetHandle()) == TRUE;
  AppendMenuW(menu, MF_STRING, kTrayMenuToggle,
              visible ? L"SplitLogを非表示" : L"SplitLogを表示");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayMenuQuit, L"SplitLogを終了");

  POINT cursor{};
  GetCursorPos(&cursor);
  suppress_auto_hide_ = true;
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, cursor.x, cursor.y,
      0, GetHandle(), nullptr);
  DestroyMenu(menu);
  suppress_auto_hide_ = false;
  PostMessageW(GetHandle(), WM_NULL, 0, 0);

  if (command == kTrayMenuToggle) {
    ToggleMainWindow();
  } else if (command == kTrayMenuQuit) {
    RequestQuit();
  } else if (!popover_locked_ && visible) {
    HideMainWindow();
  }
}

void FlutterWindow::PositionWindowNearTrayIcon() {
  const HWND window = GetHandle();
  RECT window_rect{};
  if (!GetWindowRect(window, &window_rect)) {
    return;
  }

  RECT tray_rect{};
  NOTIFYICONIDENTIFIER identifier{};
  identifier.cbSize = sizeof(NOTIFYICONIDENTIFIER);
  identifier.hWnd = window;
  identifier.uID = kTrayIconId;
  const bool has_tray_rect =
      SUCCEEDED(Shell_NotifyIconGetRect(&identifier, &tray_rect));

  const HMONITOR monitor = has_tray_rect
                               ? MonitorFromRect(&tray_rect,
                                                 MONITOR_DEFAULTTONEAREST)
                               : MonitorFromWindow(window,
                                                   MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfoW(monitor, &monitor_info)) {
    return;
  }

  const RECT work = monitor_info.rcWork;
  const int width = window_rect.right - window_rect.left;
  const int height = window_rect.bottom - window_rect.top;
  const int margin = MulDiv(kPopupMargin, GetDpiForWindow(window), 96);
  LONG x = work.right - width - margin;
  LONG y = work.bottom - height - margin;

  if (has_tray_rect) {
    const LONG icon_center_x = (tray_rect.left + tray_rect.right) / 2;
    const LONG icon_center_y = (tray_rect.top + tray_rect.bottom) / 2;
    if (tray_rect.top >= work.bottom) {
      x = icon_center_x - width / 2;
      y = work.bottom - height - margin;
    } else if (tray_rect.bottom <= work.top) {
      x = icon_center_x - width / 2;
      y = work.top + margin;
    } else if (tray_rect.left >= work.right) {
      x = work.right - width - margin;
      y = icon_center_y - height / 2;
    } else if (tray_rect.right <= work.left) {
      x = work.left + margin;
      y = icon_center_y - height / 2;
    }
  }

  x = std::clamp<LONG>(x, work.left + margin,
                       work.right - width - margin);
  y = std::clamp<LONG>(y, work.top + margin,
                       work.bottom - height - margin);
  SetWindowPos(window, nullptr, x, y, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER);
}

void FlutterWindow::ShowMainWindow() {
  if (GetHandle() == nullptr) {
    return;
  }
  KillTimer(GetHandle(), kAutoHideTimerId);
  PositionWindowNearTrayIcon();
  const HWND insert_after = popover_locked_ ? HWND_TOPMOST : HWND_TOP;
  SetWindowPos(GetHandle(), insert_after, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  ShowWindow(GetHandle(), SW_SHOWNORMAL);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::HideMainWindow() {
  if (GetHandle() != nullptr) {
    KillTimer(GetHandle(), kAutoHideTimerId);
    ShowWindow(GetHandle(), SW_HIDE);
  }
}

void FlutterWindow::ToggleMainWindow() {
  if (GetHandle() == nullptr) {
    return;
  }
  if (IsWindowVisible(GetHandle()) == TRUE) {
    HideMainWindow();
  } else {
    ShowMainWindow();
  }
}

void FlutterWindow::SetPopoverLocked(bool locked) {
  popover_locked_ = locked;
  if (GetHandle() == nullptr) {
    return;
  }
  SetWindowPos(GetHandle(), locked ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void FlutterWindow::SetShortcutsEnabled(bool enabled) {
  if (!enabled) {
    UnregisterShortcuts();
    return;
  }
  if (!registered_shortcut_ids_.empty()) {
    return;
  }

  RegisterShortcut('S', {"split", std::nullopt, std::nullopt});
  RegisterShortcut('X', {"stop", std::nullopt, std::nullopt});
  RegisterShortcut('R', {"resume", std::nullopt, std::nullopt});
  RegisterShortcut('V', {"togglePopover", std::nullopt, std::nullopt});
  RegisterShortcut('M', {"memo", std::nullopt, std::nullopt});
  for (int index = 1; index <= 9; ++index) {
    RegisterShortcut(static_cast<UINT>('0' + index),
                     {"targetLap", index, std::nullopt});
  }
  RegisterShortcut('0', {"targetLap", 0, std::nullopt});
  RegisterShortcut(VK_UP, {"moveLap", std::nullopt, -1});
  RegisterShortcut(VK_DOWN, {"moveLap", std::nullopt, 1});
}

void FlutterWindow::RegisterShortcut(UINT virtual_key, ShortcutPayload payload) {
  const int id = next_shortcut_id_++;
  if (RegisterHotKey(GetHandle(), id, kShortcutModifiers, virtual_key) == 0) {
    return;
  }
  registered_shortcut_ids_.push_back(id);
  shortcut_payloads_.emplace(id, std::move(payload));
}

void FlutterWindow::UnregisterShortcuts() {
  for (const int id : registered_shortcut_ids_) {
    UnregisterHotKey(GetHandle(), id);
  }
  registered_shortcut_ids_.clear();
  shortcut_payloads_.clear();
  next_shortcut_id_ = 1;
}

void FlutterWindow::HandleShortcut(int id) {
  const auto iterator = shortcut_payloads_.find(id);
  if (iterator == shortcut_payloads_.end()) {
    return;
  }
  const ShortcutPayload& payload = iterator->second;
  if (payload.action == "togglePopover") {
    ToggleMainWindow();
    return;
  }

  ShowMainWindow();
  if (!app_channel_) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("action")] =
      flutter::EncodableValue(payload.action);
  if (payload.index.has_value()) {
    arguments[flutter::EncodableValue("index")] =
        flutter::EncodableValue(payload.index.value());
  }
  if (payload.offset.has_value()) {
    arguments[flutter::EncodableValue("offset")] =
        flutter::EncodableValue(payload.offset.value());
  }
  app_channel_->InvokeMethod(
      "shortcutAction",
      std::make_unique<flutter::EncodableValue>(arguments));
}

void FlutterWindow::ChooseLegacyFile(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::array<wchar_t, 32768> path{};
  const wchar_t filter[] =
      L"JSON ファイル (*.json)\0*.json\0すべてのファイル (*.*)\0*.*\0\0";
  OPENFILENAMEW dialog{};
  dialog.lStructSize = sizeof(OPENFILENAMEW);
  dialog.hwndOwner = GetHandle();
  dialog.lpstrFilter = filter;
  dialog.lpstrFile = path.data();
  dialog.nMaxFile = static_cast<DWORD>(path.size());
  dialog.lpstrTitle = L"旧SplitLogのsessions.jsonを選択";
  dialog.lpstrDefExt = L"json";
  dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR |
                 OFN_DONTADDTORECENT;

  suppress_auto_hide_ = true;
  const BOOL selected = GetOpenFileNameW(&dialog);
  suppress_auto_hide_ = false;
  if (selected == FALSE) {
    result->Success();
    return;
  }

  std::ifstream stream(std::filesystem::path(path.data()),
                       std::ios::binary | std::ios::in);
  if (!stream.is_open()) {
    result->Error("read_failed", "sessions.jsonを開けませんでした。");
    return;
  }
  const std::string content((std::istreambuf_iterator<char>(stream)),
                            std::istreambuf_iterator<char>());
  if (stream.bad()) {
    result->Error("read_failed", "sessions.jsonを読み込めませんでした。");
    return;
  }
  result->Success(flutter::EncodableValue(content));
}

void FlutterWindow::OpenContact(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const wchar_t contact_uri[] =
      L"mailto:hamachii.project@proton.me?subject=SplitLog%20お問い合わせ"
      L"&body=SplitLog%20version:%0D%0AWindows%20version:%0D%0A"
      L"お問い合わせ種別:%0D%0A内容:%0D%0A";
  const auto response = reinterpret_cast<INT_PTR>(
      ShellExecuteW(GetHandle(), L"open", contact_uri, nullptr, nullptr,
                    SW_SHOWNORMAL));
  if (response <= 32) {
    result->Error("open_failed", "メールアプリを開けませんでした。");
    return;
  }
  result->Success();
}

void FlutterWindow::RequestQuit() {
  if (quit_request_pending_ || quitting_) {
    return;
  }
  if (!app_channel_) {
    QuitNow();
    return;
  }

  quit_request_pending_ = true;
  app_channel_->InvokeMethod(
      "prepareToQuit", nullptr,
      std::make_unique<
          flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* value) {
            quit_request_pending_ = false;
            const auto* should_quit =
                value == nullptr ? nullptr : std::get_if<bool>(value);
            if (should_quit != nullptr && *should_quit) {
              QuitNow();
            }
          },
          [this](const std::string&, const std::string&,
                 const flutter::EncodableValue*) {
            quit_request_pending_ = false;
          },
          [this]() { quit_request_pending_ = false; }));
}

void FlutterWindow::QuitNow() {
  if (quitting_) {
    return;
  }
  quitting_ = true;
  RemoveTrayIcon();
  Destroy();
  PostQuitMessage(0);
}
