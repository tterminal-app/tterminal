#ifndef RUNNER_FILE_DRAG_H_
#define RUNNER_FILE_DRAG_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// 註冊 "tterminal/filedrag" method channel:startDrag(path) 會以檔案的
// shell IDataObject 呼叫 SHDoDragDrop,讓使用者把檔案拖到檔案總管(複製)。
void SetupFileDrag(flutter::BinaryMessenger* messenger, HWND hwnd);

#endif  // RUNNER_FILE_DRAG_H_
