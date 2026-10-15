#include "file_drop.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <ole2.h>
#include <shellapi.h>
#include <windows.h>

#include <memory>
#include <string>

// 從檔案總管把檔案拖進視窗:註冊 OLE IDropTarget,收到 CF_HDROP 就把檔案
// 路徑與放開座標(view client px)丟給 Dart,由 Dart 判斷是否落在檔案側窗
// 上、再決定複製(本地)或 SFTP 上傳(遠端)。

namespace {

// channel 要活到整個 app 生命週期
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  int len = ::WideCharToMultiByte(CP_UTF8, 0, w.c_str(),
                                  static_cast<int>(w.size()), nullptr, 0,
                                  nullptr, nullptr);
  std::string s(len, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                        s.data(), len, nullptr, nullptr);
  return s;
}

bool HasHDrop(IDataObject* data) {
  FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  return data->QueryGetData(&fmt) == S_OK;
}

// 極簡 IDropTarget:只認 CF_HDROP,一律回報 COPY 效果。實際「是否落在側窗」
// 由 Dart 端 hit-test 決定,native 不需要知道側窗位置。
class DropTarget : public IDropTarget {
 public:
  explicit DropTarget(HWND hwnd) : hwnd_(hwnd) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *ppv = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++ref_; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG r = --ref_;
    if (r == 0) delete this;
    return r;
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL,
                                      DWORD* effect) override {
    has_files_ = HasHDrop(data);
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    has_files_ = false;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL pt,
                                 DWORD* effect) override {
    *effect = DROPEFFECT_NONE;
    has_files_ = false;
    if (g_channel == nullptr || !HasHDrop(data)) return S_OK;

    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM stg;
    if (FAILED(data->GetData(&fmt, &stg))) return S_OK;

    HDROP hdrop = static_cast<HDROP>(::GlobalLock(stg.hGlobal));
    if (hdrop != nullptr) {
      UINT count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
      flutter::EncodableList paths;
      for (UINT i = 0; i < count; ++i) {
        UINT len = ::DragQueryFileW(hdrop, i, nullptr, 0);
        std::wstring buf(len + 1, L'\0');
        ::DragQueryFileW(hdrop, i, buf.data(), len + 1);
        buf.resize(len);
        paths.push_back(flutter::EncodableValue(WideToUtf8(buf)));
      }
      ::GlobalUnlock(stg.hGlobal);

      // 螢幕座標 → view client 座標(physical px);Dart 端再除以 DPR。
      POINT client = {pt.x, pt.y};
      ::ScreenToClient(hwnd_, &client);
      if (!paths.empty()) {
        flutter::EncodableMap args = {
            {flutter::EncodableValue("paths"), flutter::EncodableValue(paths)},
            {flutter::EncodableValue("x"),
             flutter::EncodableValue(static_cast<int>(client.x))},
            {flutter::EncodableValue("y"),
             flutter::EncodableValue(static_cast<int>(client.y))},
        };
        g_channel->InvokeMethod(
            "dropped", std::make_unique<flutter::EncodableValue>(args));
        *effect = DROPEFFECT_COPY;
      }
    }
    ::ReleaseStgMedium(&stg);
    return S_OK;
  }

 private:
  ULONG ref_ = 1;
  HWND hwnd_;
  bool has_files_ = false;
};

IDropTarget* g_target = nullptr;

}  // namespace

void SetupFileDrop(flutter::BinaryMessenger* messenger, HWND view_hwnd) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "tterminal/filedrop",
      &flutter::StandardMethodCodec::GetInstance());

  // 先撤掉可能已存在的 target(例如 Flutter 自己註冊的),確保換成我們的。
  ::RevokeDragDrop(view_hwnd);
  g_target = new DropTarget(view_hwnd);
  if (FAILED(::RegisterDragDrop(view_hwnd, g_target))) {
    g_target->Release();
    g_target = nullptr;
  }
}

void TeardownFileDrop(HWND view_hwnd) {
  if (g_target != nullptr) {
    ::RevokeDragDrop(view_hwnd);
    g_target->Release();
    g_target = nullptr;
  }
  g_channel = nullptr;
}
