#ifndef RUNNER_FILE_DROP_H_
#define RUNNER_FILE_DROP_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Register an OLE drop target on |view_hwnd| so files dragged from Explorer
// onto the window are delivered to Dart (channel "tterminal/filedrop",
// method "dropped" with {paths, x, y} in view client pixels).
void SetupFileDrop(flutter::BinaryMessenger* messenger, HWND view_hwnd);

// Revoke the drop target (call before OleUninitialize / window destroy).
void TeardownFileDrop(HWND view_hwnd);

#endif  // RUNNER_FILE_DROP_H_
