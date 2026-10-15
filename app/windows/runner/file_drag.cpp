#include "file_drag.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <windows.h>

#include <memory>
#include <string>

namespace {

// channel 需要活到整個 app 生命週期
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int wlen = ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(),
                                   static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(wlen, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                        w.data(), wlen);
  return w;
}

// 用 shell 建立檔案的 IDataObject(支援 CF_HDROP 等格式,Explorer 認得),
// 再交給 SHDoDragDrop 跑拖放迴圈。DROPEFFECT_COPY → 拖到資料夾 = 複製檔案。
void DoFileDrag(HWND hwnd, const std::wstring& path) {
  PIDLIST_ABSOLUTE pidl = nullptr;
  if (FAILED(::SHParseDisplayName(path.c_str(), nullptr, &pidl, 0, nullptr)) ||
      pidl == nullptr) {
    return;
  }

  IShellFolder* parent = nullptr;
  PCUITEMID_CHILD child = nullptr;
  if (SUCCEEDED(::SHBindToParent(pidl, IID_PPV_ARGS(&parent), &child))) {
    IDataObject* data = nullptr;
    if (SUCCEEDED(parent->GetUIObjectOf(hwnd, 1, &child, IID_IDataObject,
                                        nullptr,
                                        reinterpret_cast<void**>(&data)))) {
      DWORD effect = 0;
      // 使用 shell 預設 drop source;此呼叫在拖放結束前不會返回(modal)。
      ::SHDoDragDrop(hwnd, data, nullptr, DROPEFFECT_COPY | DROPEFFECT_LINK,
                     &effect);
      data->Release();
    }
    parent->Release();
  }
  ::CoTaskMemFree(pidl);
}

}  // namespace

void SetupFileDrag(flutter::BinaryMessenger* messenger, HWND hwnd) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "tterminal/filedrag",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "startDrag") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "expected map");
          return;
        }
        auto it = args->find(flutter::EncodableValue("path"));
        if (it == args->end()) {
          result->Error("bad_args", "missing path");
          return;
        }
        const auto* path = std::get_if<std::string>(&it->second);
        if (path == nullptr) {
          result->Error("bad_args", "path not string");
          return;
        }
        DoFileDrag(hwnd, Utf8ToWide(*path));
        result->Success();
      });
}
