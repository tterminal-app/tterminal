// 用 VS Code 開啟檔案側窗選取的項目——本地路徑直接開,遠端(SSH)走
// VS Code Remote-SSH 的 vscode-remote:// URI。
//
// 參數組裝抽成純函式(好測),實際啟動(Process)另外包。

import 'dart:io';

/// 桌面平台才有 `code` CLI;iOS/Android 不支援。
bool get vscodeSupported =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 本地路徑:`code <path>`(檔案/資料夾 VS Code 都認)。
List<String> vscodeLocalArgs(String path) => [path];

/// 遠端(SSH)路徑:`code --folder-uri|--file-uri vscode-remote://ssh-remote+<authority>/<path>`。
///
/// [authority] 是 VS Code ssh-remote 權威,格式 `user@host:port`(即分頁的
/// connInfo)。[remotePath] 是遠端絕對 POSIX 路徑(以 `/` 開頭)。[isDir]
/// 決定用 folder-uri(開資料夾)還是 file-uri(開單檔)。路徑各段做
/// percent-encode,空白/特殊字元才不會壞掉。
List<String> vscodeRemoteArgs(
  String authority,
  String remotePath, {
  required bool isDir,
}) {
  final encoded =
      remotePath.split('/').map(Uri.encodeComponent).join('/');
  final uri = 'vscode-remote://ssh-remote+$authority$encoded';
  return [isDir ? '--folder-uri' : '--file-uri', uri];
}

/// 用 VS Code 開啟(啟動 `code`)。找不到 `code` 或啟動失敗丟例外,
/// 呼叫端接住後提示使用者(通常是沒裝 VS Code 或沒加進 PATH)。
///
/// Windows 的 `code` 是 `code.cmd`(批次檔),必須經 shell 才跑得起來;
/// macOS/Linux 直接執行 PATH 上的 `code`。
Future<void> launchVscode(List<String> args, {ProcessRunner? runner}) async {
  final run = runner ?? _defaultRunner;
  final result = await run('code', args, Platform.isWindows);
  if (result != 0) {
    throw ProcessException('code', args, 'exit code $result', result);
  }
}

/// 啟動子行程,回傳結束碼;抽成型別方便測試注入。
typedef ProcessRunner = Future<int> Function(
  String executable,
  List<String> args,
  bool runInShell,
);

Future<int> _defaultRunner(
  String executable,
  List<String> args,
  bool runInShell,
) async {
  final result = await Process.run(executable, args, runInShell: runInShell);
  return result.exitCode;
}
