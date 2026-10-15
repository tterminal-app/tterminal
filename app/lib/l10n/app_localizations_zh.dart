// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get cancel => '取消';

  @override
  String get save => '儲存';

  @override
  String get delete => '刪除';

  @override
  String get close => '關閉';

  @override
  String get copy => '複製';

  @override
  String get clear => '清除';

  @override
  String get reset => '重設';

  @override
  String get refresh => '重新整理';

  @override
  String get reconnect => '重新連線';

  @override
  String get settings => '設定';

  @override
  String get gotIt => '知道了';

  @override
  String get unknownError => '未知錯誤';

  @override
  String get connecting => '連線中…';

  @override
  String get ended => '已結束';

  @override
  String remotePath(String path) {
    return '遠端:$path';
  }

  @override
  String get vaults => 'Vaults';

  @override
  String get hosts => 'Hosts';

  @override
  String get keys => 'Keys';

  @override
  String get vaultsTooltip => 'Vaults(Hosts / Keys)';

  @override
  String get vaultsTooltipMobile => 'Vaults(Hosts/Keys 管理)';

  @override
  String get vaultOpenFailedTitle => 'Vault 無法開啟';

  @override
  String vaultOpenFailed(String error) {
    return 'Vault 無法開啟:$error';
  }

  @override
  String tabTitleDefault(int id) {
    return '終端機 $id';
  }

  @override
  String tabTitleConnecting(String title) {
    return '$title(連線中…)';
  }

  @override
  String tabTitleEnded(String title) {
    return '$title(已結束)';
  }

  @override
  String get newTabTooltip => '新分頁(Ctrl+Shift+T)';

  @override
  String get closeTabTooltip => '關閉(Ctrl+Shift+W)';

  @override
  String get closeTab => '關閉分頁';

  @override
  String get filesPanelTooltip => '檔案側窗';

  @override
  String get localTerminal => '本機終端機';

  @override
  String get noLocalShell => '無本地 shell';

  @override
  String get connectionFailed => '連線失敗';

  @override
  String get wheelCaptured => '滾輪由程式接管';

  @override
  String get wheelCapturedTooltip =>
      '前景程式接管了滑鼠滾輪(全螢幕程式 / 滑鼠回報模式)。\n程式被強制中斷後模式可能沒還原,按「重設終端」即可恢復捲動。';

  @override
  String get resetTerminal => '重設終端';

  @override
  String get restartingTerminal => '重新啟動終端…';

  @override
  String connectingTo(String name) {
    return '連線到 $name …';
  }

  @override
  String get localShellUnavailable => '此裝置不支援本地 shell(iOS 限制)';

  @override
  String get openVaultsForSsh => '開啟 Vaults 連線 SSH';

  @override
  String terminalStartFailed(String error) {
    return '無法啟動終端\n\n$error';
  }

  @override
  String localShellFailed(String error) {
    return '無法開啟 shell:$error';
  }

  @override
  String get sshConnectFailed => 'SSH 連線失敗';

  @override
  String get reconnectTitle => '重新連線?';

  @override
  String reconnectBody(String title) {
    return '「$title」目前的連線會被中斷,重新建立一個新的。';
  }

  @override
  String get cwdNotFound => '抓不到終端目前的目錄';

  @override
  String get vscodeNoRemoteInfo => '抓不到遠端連線資訊,無法用 VS Code 開啟';

  @override
  String get vscodeNotFound => '找不到 VS Code(code)—請確認已安裝並加入 PATH';

  @override
  String get discardEditsTitle => '捨棄未存檔的修改?';

  @override
  String discardEditsBody(String file) {
    return '$file 有未存檔的修改。';
  }

  @override
  String get discard => '捨棄';

  @override
  String get dragOutTooLarge => '檔案太大,無法直接拖出(可用編輯器開啟後另存)';

  @override
  String readRemoteFileFailed(String error) {
    return '讀取遠端檔案失敗:$error';
  }

  @override
  String filesUploaded(int count, String dir) {
    return '已上傳 $count 個檔案到遠端 $dir';
  }

  @override
  String filesCopied(int count, String dir) {
    return '已複製 $count 個檔案到$dir';
  }

  @override
  String filesUploadedPartly(int count, String skipped) {
    return '上傳 $count 個;略過:$skipped';
  }

  @override
  String filesCopiedPartly(int count, String skipped) {
    return '複製 $count 個;略過:$skipped';
  }

  @override
  String skippedFolder(String name) {
    return '$name(資料夾)';
  }

  @override
  String skippedTooLarge(String name) {
    return '$name(太大)';
  }

  @override
  String skippedWithReason(String name, String reason) {
    return '$name($reason)';
  }

  @override
  String get keyHookUnknownTool => '某個常駐的聽寫/巨集工具';

  @override
  String keyHookTool(String tool) {
    return '$tool(它正在執行)';
  }

  @override
  String keyHookWarning(String who) {
    return '空白鍵可能被系統層的全域鍵盤 hook 攔走了:剛剛連續輸入這麼多字元卻沒有任何空白。常見原因是 $who 的熱鍵含空白鍵,它必須攔下每個空白等著看組合鍵,狀態卡住就再也不放行。重啟該工具或改掉它的熱鍵即可;被攔掉的按鍵終端這邊完全收不到,不是終端的問題。';
  }

  @override
  String deleteConfirm(String name) {
    return '確定要刪除「$name」?此操作會同步到所有裝置。';
  }

  @override
  String get hostSearchHint => '搜尋名稱、位址、使用者、備註';

  @override
  String get addHost => '新增 Host';

  @override
  String get editHost => '編輯 Host';

  @override
  String hostCount(int count) {
    return '$count 台主機';
  }

  @override
  String hostCountFiltered(int shown, int total) {
    return '$shown / $total 台主機';
  }

  @override
  String get hostsEmpty => '還沒有主機,按「新增 Host」開始';

  @override
  String get hostsNoMatch => '沒有符合搜尋的主機';

  @override
  String get keyDeleted => '(金鑰已刪除)';

  @override
  String hostKeyName(String name) {
    return '金鑰:$name';
  }

  @override
  String get pin => '置頂';

  @override
  String get unpin => '取消置頂';

  @override
  String get sshConnect => 'SSH 連線';

  @override
  String get nameRequiredLabel => '名稱 *';

  @override
  String get addressRequiredLabel => '位址 *';

  @override
  String get port => 'Port';

  @override
  String get username => '使用者';

  @override
  String get authMethod => '認證方式';

  @override
  String get password => '密碼';

  @override
  String get sshKey => 'SSH 金鑰';

  @override
  String get authNone => '無(互動輸入)';

  @override
  String get key => '金鑰';

  @override
  String get note => '備註';

  @override
  String get hostRequiredFields => '名稱與位址為必填';

  @override
  String get sshKeyMissing => '此 Host 指定的 SSH 金鑰已不存在';

  @override
  String keyCount(int count) {
    return '$count 把金鑰';
  }

  @override
  String get addKey => '新增 Key';

  @override
  String get keysEmpty => '還沒有金鑰,按「新增 Key」貼上私鑰';

  @override
  String get addSshKey => '新增 SSH Key';

  @override
  String get editSshKey => '編輯 SSH Key';

  @override
  String get privateKeyRequiredLabel => '私鑰(貼上 OpenSSH / PEM)*';

  @override
  String get passphraseOptionalLabel => 'Passphrase(可空)';

  @override
  String get keyRequiredFields => '名稱與私鑰為必填';

  @override
  String get publicKeyCopied => '公鑰已複製,貼到遠端 ~/.ssh/authorized_keys';

  @override
  String publicKeyFailed(String error) {
    return '算不出公鑰:$error';
  }

  @override
  String get publicKeyPending => '公鑰計算中';

  @override
  String get copyPublicKey => '複製公鑰';

  @override
  String publicKeyWithFingerprint(String fingerprint) {
    return '公鑰($fingerprint)';
  }

  @override
  String deleteFailed(String error) {
    return '刪除失敗:$error';
  }

  @override
  String get tabBarPosition => '分頁列位置';

  @override
  String get tabBarTop => '上方(橫向)';

  @override
  String get tabBarSide => '側邊(垂直列表)';

  @override
  String get terminalFontSize => '終端機字體大小';

  @override
  String get fontSmaller => '縮小';

  @override
  String get fontLarger => '放大';

  @override
  String get fontSizeHint => '在終端機也可用 Ctrl +/-、Ctrl 0 或 Ctrl+滾輪調整';

  @override
  String get syncSection => '同步(self-host server)';

  @override
  String get syncNotConfigured => '尚未設定同步。可以在這台機器建立,或貼上其他裝置匯出的配對字串。';

  @override
  String get syncServerLabel => '同步伺服器位置';

  @override
  String get setUpSync => '建立同步';

  @override
  String get joinWithPairing => '貼上配對字串加入';

  @override
  String get syncing => '同步中…';

  @override
  String syncFailed(String error) {
    return '同步失敗:$error';
  }

  @override
  String lastSynced(String time) {
    return '上次同步:$time';
  }

  @override
  String get notSyncedYet => '尚未同步';

  @override
  String pendingChanges(int count) {
    return '待推送 $count 筆';
  }

  @override
  String get syncNow => '立即同步';

  @override
  String get exportPairing => '匯出配對字串';

  @override
  String get turnOffSync => '停用同步';

  @override
  String get pastePairingTitle => '貼上配對字串';

  @override
  String get join => '加入';

  @override
  String joinedVault(int count) {
    return '已加入 vault(併入本地 $count 筆資料)';
  }

  @override
  String get pairingStringTitle => '配對字串';

  @override
  String get pairingWarning =>
      '⚠️ 這段字串含同步伺服器位置、認證 token 與加密金鑰。拿到它的人可以完整讀寫這個 vault——只在你自己的裝置間傳遞。';

  @override
  String get turnOffSyncBody => '只會斷開與伺服器的連線,本地資料完整保留。確定?';

  @override
  String get turnOff => '停用';

  @override
  String turnOffSyncFailed(String error) {
    return '停用同步失敗:$error';
  }

  @override
  String get serverAddressEmpty => 'server 位置不可為空';

  @override
  String syncServerResponded(int status, String message) {
    return 'server 回應 $status:$message';
  }

  @override
  String get syncUnauthorized => '同步伺服器不接受這台裝置的憑證,可能需要重新配對';

  @override
  String get syncVaultNotFound => '同步伺服器上已經沒有這個 vault';

  @override
  String get syncVaultConflict => '這個 vault 已經用別的憑證在同步伺服器上註冊過了';

  @override
  String conflictCopyName(String name, String device, String time) {
    return '$name(衝突副本 $device @$time)';
  }

  @override
  String get activeSessions => '進行中';

  @override
  String get mobileNoHosts => '還沒有 host。點右上角 ⛁ 開 Vaults 新增 SSH 主機。';

  @override
  String get pickConnectionHint => '從左邊選一條連線或一台主機';

  @override
  String get sessionConnected => '連線中(執行中)';

  @override
  String get disconnectAndRemove => '斷線並移除';

  @override
  String get connections => '連線';

  @override
  String get hideConnectionList => '收起連線列';

  @override
  String get showConnectionList => '展開連線列';

  @override
  String get disconnect => '斷線';

  @override
  String connectFailedBody(String error) {
    return '無法連線\n\n$error';
  }

  @override
  String get tapToType => '點這裡打字';

  @override
  String get readOnlyTooLarge => '檔案超過 5MB,唯讀預覽';

  @override
  String get readOnlyBinary => '二進位檔,不支援編輯';

  @override
  String get savedRemote => '已儲存(遠端)';

  @override
  String get saved => '已儲存';

  @override
  String saveFailed(String error) {
    return '儲存失敗:$error';
  }

  @override
  String linkOpenFailed(String url) {
    return '打不開這個連結:$url';
  }

  @override
  String get fileChangedTitle => '檔案已被外部修改';

  @override
  String get fileChangedBody => '這個檔案在你編輯期間被其他程式改過。要用你的版本覆蓋嗎?';

  @override
  String get overwrite => '覆蓋';

  @override
  String get showSource => '顯示原始碼';

  @override
  String get previewMarkdown => '預覽 Markdown';

  @override
  String get saveTooltip => '儲存(Ctrl+S)';

  @override
  String get closeEscTooltip => '關閉(Esc)';

  @override
  String fileOpenFailed(String error) {
    return '無法開啟\n$error';
  }

  @override
  String get openInVscode => '用 VS Code 開啟';

  @override
  String get parentFolder => '上一層';

  @override
  String get jumpToCwd => '跳至終端目前目錄(切到作用中分頁)';

  @override
  String get followCwdOn => '跟隨終端目錄(開)';

  @override
  String get followCwdOff => '跟隨終端目錄(關)';

  @override
  String listDirFailed(String error) {
    return '無法讀取目錄\n$error';
  }

  @override
  String get emptyFolder => '(空目錄)';

  @override
  String errHostKeyMismatch(String expected, String actual) {
    return 'host key 不符!預期 $expected,實際 $actual。連線已中止(可能遭中間人攻擊,或伺服器主機金鑰已更換)。';
  }

  @override
  String errTimeout(String op) {
    String _temp0 = intl.Intl.selectLogic(op, {
      'list_dir': 'SFTP 列目錄 逾時(連線可能已中斷)',
      'home': 'SFTP home 逾時(連線可能已中斷)',
      'read_file': 'SFTP 讀檔 逾時(連線可能已中斷)',
      'write_file': 'SFTP 寫檔 逾時(連線可能已中斷)',
      'exec': 'exec 逾時',
      'other': '逾時(連線可能已中斷)',
    });
    return '$_temp0';
  }

  @override
  String errPrivateKeyUnreadable(String reason) {
    return '讀不出私鑰:$reason';
  }

  @override
  String get errPairingMissingPrefix => '不是 tterminal 配對字串(缺少 TTERMSYNC1: 前綴)';

  @override
  String errPairingUnsupportedVersion(int version) {
    return '配對字串版本 $version 不支援(此版本只支援 v1)';
  }

  @override
  String get errPairingMalformed => '配對字串不完整或已損毀,請重新複製一次';

  @override
  String get errDecryptFailed => '解密失敗(金鑰不符或資料被竄改)';
}
