#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "file_drag.h"
#include "file_drop.h"
#include "text_input_provider.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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
  // 檔案拖出到檔案總管(native OLE CF_HDROP)
  SetupFileDrag(flutter_controller_->engine()->messenger(), GetHandle());
  // 聽寫/口語轉文字(UIA IValueProvider → 終端):subclass 有焦點的
  // FLUTTERVIEW 子視窗,聽寫工具查焦點視窗時就拿得到可編輯文字元素。
  SetupDictationChannel(flutter_controller_->engine()->messenger());
  HWND view_window = flutter_controller_->view()->GetNativeWindow();
  InstallTerminalUiaSubclass(view_window);
  // 從檔案總管把檔案拖進來(native OLE IDropTarget → Dart 檔案側窗)
  SetupFileDrop(flutter_controller_->engine()->messenger(), view_window);
  SetChildContent(view_window);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    TeardownFileDrop(flutter_controller_->view()->GetNativeWindow());
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
