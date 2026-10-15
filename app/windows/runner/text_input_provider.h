#ifndef RUNNER_TEXT_INPUT_PROVIDER_H_
#define RUNNER_TEXT_INPUT_PROVIDER_H_

#include <flutter/binary_messenger.h>
#include <uiautomation.h>
#include <windows.h>

#include <string>

// 送到 UI thread 的自訂訊息:UIA client(typeless 等聽寫工具)透過
// IValueProvider::SetValue 插入的文字。lParam = new std::wstring*(要 delete)。
constexpr UINT WM_TTERM_DICTATE = WM_APP + 0x51;

// Flutter 在 Windows stable 未開 native UIA(engine issue #114547),自繪終端在
// UIA 只是個沒有 pattern 的 Pane,聽寫工具插不進去。這裡自己提供一個支援
// IValueProvider 的 UIA 元素,SetValue 會 PostMessage(WM_TTERM_DICTATE) 回 UI
// thread,再經 method channel 送進終端。
//
// subclass 有焦點的 FLUTTERVIEW 子視窗,攔截它的 UIA WM_GETOBJECT。
// 聽寫工具查「焦點視窗」時就會拿到我們的可編輯文字元素。
void InstallTerminalUiaSubclass(HWND child);

// 建立 "tterminal/dictate" channel(native → Dart 單向送插入文字)。
void SetupDictationChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_TEXT_INPUT_PROVIDER_H_
