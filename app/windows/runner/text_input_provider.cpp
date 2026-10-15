#include "text_input_provider.h"

#include <commctrl.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <uiautomation.h>
#include <windows.h>

#include <memory>
#include <string>

#include <atomic>

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_dictate;

// Flutter 端回報的「終端是否持有焦點」。攔 Ctrl+V / 吞 WM_CHAR 只在終端有
// 焦點時做;焦點在設定頁等文字框時完全不干預,讓 Flutter 自己的按鍵管線
// 正常處理貼上(否則 TextField 永遠收不到 Ctrl+V)。
std::atomic<bool> g_terminal_focused{false};

void DispatchDictation(const std::wstring& text);

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

// 極簡 ITextRangeProvider:代表「文件裡的一個(空)範圍」。終端沒有真的文字
// 緩衝,所以文字都回空、移動都回 0;重點是讓聽寫工具認得這是可編輯文字控制。
class TermTextRange : public ITextRangeProvider {
 public:
  explicit TermTextRange(IRawElementProviderSimple* owner)
      : owner_(owner), ref_(1) {
    if (owner_) owner_->AddRef();
  }
  ~TermTextRange() {
    if (owner_) owner_->Release();
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return r;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_INVALIDARG;
    if (riid == IID_IUnknown || riid == IID_ITextRangeProvider) {
      *ppv = static_cast<ITextRangeProvider*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE Clone(ITextRangeProvider** ret) override {
    *ret = new TermTextRange(owner_);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Compare(ITextRangeProvider*, BOOL* ret) override {
    *ret = TRUE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE CompareEndpoints(TextPatternRangeEndpoint,
                                             ITextRangeProvider*,
                                             TextPatternRangeEndpoint,
                                             int* ret) override {
    *ret = 0;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE ExpandToEnclosingUnit(TextUnit) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE FindAttribute(TEXTATTRIBUTEID, VARIANT, BOOL,
                                          ITextRangeProvider** ret) override {
    *ret = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE FindText(BSTR, BOOL, BOOL,
                                     ITextRangeProvider** ret) override {
    *ret = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetAttributeValue(TEXTATTRIBUTEID,
                                              VARIANT* ret) override {
    VariantInit(ret);
    IUnknown* not_supported = nullptr;
    if (SUCCEEDED(UiaGetReservedNotSupportedValue(&not_supported))) {
      ret->vt = VT_UNKNOWN;
      ret->punkVal = not_supported;
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetBoundingRectangles(SAFEARRAY** ret) override {
    *ret = SafeArrayCreateVector(VT_R8, 0, 0);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetEnclosingElement(
      IRawElementProviderSimple** ret) override {
    *ret = owner_;
    if (owner_) owner_->AddRef();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetText(int, BSTR* ret) override {
    *ret = SysAllocString(L"");
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Move(TextUnit, int, int* ret) override {
    *ret = 0;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE MoveEndpointByUnit(TextPatternRangeEndpoint,
                                               TextUnit, int,
                                               int* ret) override {
    *ret = 0;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE MoveEndpointByRange(
      TextPatternRangeEndpoint, ITextRangeProvider*,
      TextPatternRangeEndpoint) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Select() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE AddToSelection() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE ScrollIntoView(BOOL) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE GetChildren(SAFEARRAY** ret) override {
    *ret = SafeArrayCreateVector(VT_UNKNOWN, 0, 0);
    return S_OK;
  }

 private:
  IRawElementProviderSimple* owner_;
  ULONG ref_;
};

// 單一 UIA 元素:對 UIA 而言是可編輯文字控制(Edit),支援 Value 與 Text
// pattern。聽寫工具(typeless)靠 TextPattern 才認得這是文字欄位、才會插字。
// 同時實作 fragment / fragment root,讓 FocusedElement 找得到它。
class TerminalTextProvider : public IRawElementProviderSimple,
                             public IRawElementProviderFragment,
                             public IRawElementProviderFragmentRoot,
                             public IValueProvider,
                             public ITextProvider2 {
 public:
  explicit TerminalTextProvider(HWND hwnd) : hwnd_(hwnd), ref_(1) {}

  // IUnknown
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return r;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_INVALIDARG;
    if (riid == IID_IUnknown || riid == IID_IRawElementProviderSimple) {
      *ppv = static_cast<IRawElementProviderSimple*>(this);
    } else if (riid == IID_IRawElementProviderFragment) {
      *ppv = static_cast<IRawElementProviderFragment*>(this);
    } else if (riid == IID_IRawElementProviderFragmentRoot) {
      *ppv = static_cast<IRawElementProviderFragmentRoot*>(this);
    } else if (riid == IID_IValueProvider) {
      *ppv = static_cast<IValueProvider*>(this);
    } else if (riid == IID_ITextProvider) {
      *ppv = static_cast<ITextProvider*>(static_cast<ITextProvider2*>(this));
    } else if (riid == IID_ITextProvider2) {
      *ppv = static_cast<ITextProvider2*>(this);
    } else {
      *ppv = nullptr;
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }

  // IRawElementProviderSimple
  HRESULT STDMETHODCALLTYPE get_ProviderOptions(
      ProviderOptions* opts) override {
    *opts = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider |
                                         ProviderOptions_UseComThreading);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id,
                                               IUnknown** ret) override {
    *ret = nullptr;
    if (id == UIA_ValuePatternId) {
      *ret = static_cast<IValueProvider*>(this);
      AddRef();
    } else if (id == UIA_TextPatternId) {
      *ret = static_cast<ITextProvider*>(static_cast<ITextProvider2*>(this));
      AddRef();
    } else if (id == UIA_TextPattern2Id) {
      *ret = static_cast<ITextProvider2*>(this);
      AddRef();
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID id,
                                             VARIANT* ret) override {
    VariantInit(ret);
    switch (id) {
      case UIA_ControlTypePropertyId:
        ret->vt = VT_I4;
        ret->lVal = UIA_EditControlTypeId;
        break;
      case UIA_IsKeyboardFocusablePropertyId:
      case UIA_IsContentElementPropertyId:
      case UIA_IsControlElementPropertyId:
      case UIA_IsEnabledPropertyId:
      case UIA_HasKeyboardFocusPropertyId:
      case UIA_IsTextPatternAvailablePropertyId:
      case UIA_IsValuePatternAvailablePropertyId:
        ret->vt = VT_BOOL;
        ret->boolVal = VARIANT_TRUE;
        break;
      case UIA_NamePropertyId:
        ret->vt = VT_BSTR;
        ret->bstrVal = SysAllocString(L"Terminal input");
        break;
      case UIA_AutomationIdPropertyId:
        ret->vt = VT_BSTR;
        ret->bstrVal = SysAllocString(L"tterminal_input");
        break;
      default:
        break;
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(
      IRawElementProviderSimple** ret) override {
    return UiaHostProviderFromHwnd(hwnd_, ret);
  }

  // IRawElementProviderFragment
  HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection,
                                     IRawElementProviderFragment** ret)
      override {
    *ret = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY** ret) override {
    int rid[] = {UiaAppendRuntimeId, 1};
    *ret = SafeArrayCreateVector(VT_I4, 0, 2);
    if (*ret) {
      for (LONG i = 0; i < 2; i++) SafeArrayPutElement(*ret, &i, &rid[i]);
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect* ret) override {
    RECT r;
    GetClientRect(hwnd_, &r);
    POINT tl{r.left, r.top};
    ClientToScreen(hwnd_, &tl);
    ret->left = tl.x;
    ret->top = tl.y;
    ret->width = r.right - r.left;
    ret->height = r.bottom - r.top;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY** ret) override {
    *ret = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetFocus() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE get_FragmentRoot(
      IRawElementProviderFragmentRoot** ret) override {
    *ret = static_cast<IRawElementProviderFragmentRoot*>(this);
    AddRef();
    return S_OK;
  }

  // IRawElementProviderFragmentRoot
  HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(
      double, double, IRawElementProviderFragment** ret) override {
    *ret = static_cast<IRawElementProviderFragment*>(this);
    AddRef();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetFocus(
      IRawElementProviderFragment** ret) override {
    *ret = static_cast<IRawElementProviderFragment*>(this);
    AddRef();
    return S_OK;
  }

  // IValueProvider —— 聽寫工具若走 ValuePattern 插字就到這裡
  HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR value) override {
    if (value && *value) {
      auto* text = new std::wstring(value);
      if (!PostMessageW(hwnd_, WM_TTERM_DICTATE, 0,
                        reinterpret_cast<LPARAM>(text))) {
        delete text;
      }
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_Value(BSTR* ret) override {
    *ret = SysAllocString(L"");
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL* ret) override {
    *ret = FALSE;
    return S_OK;
  }

  // ITextProvider —— 讓聽寫工具認得這是文字控制(才會嘗試插字)
  HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY** ret) override {
    *ret = SingleRange();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetVisibleRanges(SAFEARRAY** ret) override {
    *ret = SingleRange();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE RangeFromChild(
      IRawElementProviderSimple*, ITextRangeProvider** ret) override {
    *ret = new TermTextRange(this);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE RangeFromPoint(UiaPoint,
                                           ITextRangeProvider** ret) override {
    *ret = new TermTextRange(this);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_DocumentRange(
      ITextRangeProvider** ret) override {
    *ret = new TermTextRange(this);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_SupportedTextSelection(
      SupportedTextSelection* ret) override {
    *ret = SupportedTextSelection_Single;
    return S_OK;
  }

  // ITextProvider2
  HRESULT STDMETHODCALLTYPE GetCaretRange(BOOL* is_active,
                                          ITextRangeProvider** ret) override {
    *is_active = TRUE;
    *ret = new TermTextRange(this);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE RangeFromAnnotation(
      IRawElementProviderSimple*, ITextRangeProvider** ret) override {
    *ret = new TermTextRange(this);
    return S_OK;
  }

 private:
  SAFEARRAY* SingleRange() {
    SAFEARRAY* sa = SafeArrayCreateVector(VT_UNKNOWN, 0, 1);
    if (sa) {
      auto* r = new TermTextRange(this);
      LONG i = 0;
      SafeArrayPutElement(sa, &i, static_cast<ITextRangeProvider*>(r));
      r->Release();
    }
    return sa;
  }

  HWND hwnd_;
  ULONG ref_;
};

void DispatchDictation(const std::wstring& text) {
  if (!g_dictate) return;
  auto args = std::make_unique<flutter::EncodableValue>(
      flutter::EncodableValue(WideToUtf8(text)));
  g_dictate->InvokeMethod("insert", std::move(args));
}

// 同步讀剪貼簿文字(CF_UNICODETEXT)。native 端讀,才不會被聽寫工具「貼完
// 馬上還原剪貼簿」的競態搶走(Dart 端是非同步讀)。
std::wstring ReadClipboardText(HWND owner) {
  if (!::OpenClipboard(owner)) return std::wstring();
  std::wstring text;
  HANDLE h = ::GetClipboardData(CF_UNICODETEXT);
  if (h != nullptr) {
    auto* p = static_cast<const wchar_t*>(::GlobalLock(h));
    if (p != nullptr) {
      text = p;
      ::GlobalUnlock(h);
    }
  }
  ::CloseClipboard();
  return text;
}

void DispatchPaste(const std::wstring& text) {
  if (!g_dictate) return;
  g_dictate->InvokeMethod(
      "paste", std::make_unique<flutter::EncodableValue>(WideToUtf8(text)));
}

// subclass proc:攔截 FLUTTERVIEW 子視窗的 UIA WM_GETOBJECT 與插字訊息,
// 並在 native 攔 Ctrl+V(聽寫工具的貼上路徑)。
LRESULT CALLBACK TermSubclassProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp,
                                  UINT_PTR, DWORD_PTR) {
  // 聽寫工具(typeless)靠 Ctrl+V 貼上,但它合成的按鍵讓 Flutter 的
  // HardwareKeyboard 抓不到 Ctrl(V 事件的 isControlPressed=false),貼上就不會
  // 觸發。改在 native 用 OS 真實鍵態偵測 Ctrl+V,同步讀剪貼簿直接送去貼。
  // 只在終端持有焦點時攔;焦點在其他文字框時交還給 Flutter 的標準貼上。
  if (g_terminal_focused.load(std::memory_order_relaxed)) {
    if ((msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) && wp == 'V' &&
        (::GetKeyState(VK_CONTROL) & 0x8000)) {
      std::wstring clip = ReadClipboardText(hwnd);
      if (!clip.empty()) DispatchPaste(clip);
    }
    // 吞掉 Ctrl+V 的控制字元(0x16 SYN),免得它變成 ^V 混進終端。
    if (msg == WM_CHAR && wp == 0x16) {
      return 0;
    }
  }

  if (msg == WM_GETOBJECT) {
    DWORD obj_id = static_cast<DWORD>(static_cast<DWORD_PTR>(lp));
    if (obj_id == static_cast<DWORD>(UiaRootObjectId)) {
      auto* provider = new TerminalTextProvider(hwnd);
      LRESULT result = UiaReturnRawElementProvider(hwnd, wp, lp, provider);
      provider->Release();
      return result;
    }
  } else if (msg == WM_TTERM_DICTATE) {
    auto* text = reinterpret_cast<std::wstring*>(lp);
    if (text) {
      DispatchDictation(*text);
      delete text;
    }
    return 0;
  }
  return DefSubclassProc(hwnd, msg, wp, lp);
}

}  // namespace

void InstallTerminalUiaSubclass(HWND child) {
  ::SetWindowSubclass(child, TermSubclassProc, 1, 0);
}

void SetupDictationChannel(flutter::BinaryMessenger* messenger) {
  g_dictate = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "tterminal/dictate",
      &flutter::StandardMethodCodec::GetInstance());
  // Dart 端在終端焦點變化時回報,決定 native 要不要攔 Ctrl+V。
  g_dictate->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "terminalFocus") {
          const auto* focused =
              call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
          g_terminal_focused.store(focused != nullptr && *focused,
                                   std::memory_order_relaxed);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}
