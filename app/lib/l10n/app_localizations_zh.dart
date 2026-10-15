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
  String get keysEmpty => '還沒有金鑰。按「產生金鑰」建立新的,或按「新增 Key」貼上既有的私鑰';

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
  String get generateKey => '產生金鑰';

  @override
  String get generateSshKey => '產生 SSH 金鑰';

  @override
  String get keyType => '類型';

  @override
  String get keyTypeEd25519 => 'Ed25519(建議)';

  @override
  String get keyTypeRsa => 'RSA 4096(相容舊伺服器)';

  @override
  String get passphraseRepeatLabel => '再輸入一次 passphrase';

  @override
  String get keygenPassphraseHint =>
      '可以留空。設定的話私鑰會用它加密;passphrase 會跟金鑰一起存在 vault,連線時自動帶入。';

  @override
  String get passphraseMismatch => '兩次輸入的 passphrase 不一樣';

  @override
  String get keygenNameRequired => '名稱為必填';

  @override
  String get generate => '產生';

  @override
  String get generatingKey => '產生中…';

  @override
  String get keyGenerated => '金鑰已產生';

  @override
  String keyGeneratedBody(String name) {
    return '已存進 Keys(名稱「$name」)。把下面這行公鑰加到伺服器的 ~/.ssh/authorized_keys,再到 Host 設定選這把金鑰,就能用它登入。';
  }

  @override
  String keygenFailed(String error) {
    return '產生金鑰失敗:$error';
  }

  @override
  String get done => '完成';

  @override
  String get undo => '復原';

  @override
  String get hostFingerprint => '主機指紋';

  @override
  String get hostFingerprintNone => '還沒記住。第一次連線時會記下伺服器的主機金鑰指紋,之後每次連線都會比對。';

  @override
  String get hostFingerprintClearHint =>
      '只有伺服器重灌或換了主機金鑰時才需要清除。清除後,下次連線會直接信任伺服器出示的金鑰並重新記住。';

  @override
  String get hostFingerprintWillClear => '儲存後會清除,下次連線時重新記住伺服器出示的金鑰。';

  @override
  String get hostFingerprintAddressChanged =>
      '位址或 Port 改了,儲存時會一併清除記住的指紋(那是舊主機的)。';

  @override
  String get hostKeyChangedTitle => '主機金鑰跟上次不一樣';

  @override
  String hostKeyChangedBody(String name) {
    return '「$name」這次出示的主機金鑰,跟第一次連線時記住的不一樣,所以連線已經中止。\n\n可能是伺服器重灌、或管理員換了主機金鑰;但也可能有人正在攔截這條連線(中間人攻擊)。確認之前請不要繼續。';
  }

  @override
  String get hostKeyRemembered => '記住的指紋';

  @override
  String get hostKeyPresented => '這次收到的指紋';

  @override
  String get hostKeyHowToVerify =>
      '怎麼確認:請伺服器管理員在伺服器上執行 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub,把結果跟「這次收到的指紋」逐字比對,必須完全一樣。';

  @override
  String get hostKeyTrustNew => '我確認主機換過了,改用新指紋…';

  @override
  String get hostKeyNotInVault => '這台 Host 已經不在 Vaults 裡,沒辦法在這裡更新指紋。';

  @override
  String get hostKeyTrustTitle => '改用新的主機金鑰?';

  @override
  String hostKeyTrustBody(String name) {
    return '之後連到「$name」只認這把新金鑰,舊的指紋會被忘掉。如果其實是有人在攔截連線,改用之後你送出的所有內容(包括密碼)都可能被對方看到。';
  }

  @override
  String get hostKeyTrustCheckbox => '我已經透過其他管道核對過新指紋,完全一致';

  @override
  String get hostKeyTrustConfirm => '改用新指紋並重新連線';

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

  @override
  String get purchaseSection => '試用與解鎖';

  @override
  String get accessLoading => '正在確認購買狀態…';

  @override
  String get accessNotStarted => '還沒開始試用';

  @override
  String get accessNotStartedHint => '想用的時候再開始就好,開始後 14 天內所有功能都能免費用。';

  @override
  String accessTrial(int days) {
    return '試用中,還有 $days 天';
  }

  @override
  String accessTrialHint(String date) {
    return '所有功能可以用到 $date。';
  }

  @override
  String get accessExpired => '試用已結束';

  @override
  String get accessExpiredHint => '主機、金鑰和同步照常可以用;要開新的連線需要先解鎖。';

  @override
  String get accessUnlocked => '已解鎖';

  @override
  String get accessUnlockedHint => '謝謝支持!之後的 1.x 更新都包含在內。';

  @override
  String get startTrialButton => '開始 14 天試用';

  @override
  String get unlockButton => '解鎖';

  @override
  String unlockWithPrice(String price) {
    return '解鎖 $price';
  }

  @override
  String get restorePurchases => '恢復購買';

  @override
  String get notNow => '之後再說';

  @override
  String get tryAgain => '再試一次';

  @override
  String get trialIntroTitle => '先免費用 14 天';

  @override
  String get trialIntroDuration => '接下來 14 天,所有功能都可以用,開始試用不用付錢。';

  @override
  String get trialIntroAfter =>
      '試用結束後,沒有解鎖就不能再開新的 SSH 連線。主機、金鑰、Vaults 和同步都會留著,照樣可以看、可以改。';

  @override
  String trialIntroPrice(String price) {
    return '解鎖只要買一次:$price,之後的 1.x 更新都包含在內。沒有訂閱,試用結束也不會自動扣款。';
  }

  @override
  String get trialEndedTitle => '試用期結束了';

  @override
  String trialEndedBody(String price) {
    return '想繼續開新的連線,解鎖一次就好:$price,之後的 1.x 更新都包含在內。';
  }

  @override
  String get trialEndedKeepData => '謝謝你試用 tterminal。不管有沒有解鎖,主機、金鑰和同步都還在,照常可以用。';

  @override
  String get unlockTitle => '解鎖 tterminal';

  @override
  String unlockBody(String price) {
    return '一次性購買 $price,之後的 1.x 更新都包含在內,沒有訂閱。';
  }

  @override
  String unlockTrialLeft(int days) {
    return '試用還有 $days 天。';
  }

  @override
  String get priceLoading => '正在向 App Store 讀取價格…';

  @override
  String get priceUnavailable => '暫時連不上 App Store,讀不到價格。請確認網路後再試一次。';

  @override
  String get trialStarted => '試用開始了,接下來 14 天所有功能都能用。';

  @override
  String get unlockedThanks => '解鎖完成,謝謝支持!';

  @override
  String get purchasePending => '購買正在等候核准,核准後就會自動解鎖。';

  @override
  String purchaseFailed(String error) {
    return '購買沒有完成:$error';
  }

  @override
  String get restoreFoundUnlock => '已恢復購買,tterminal 解鎖了。';

  @override
  String get restoreNothing => '這個 Apple 帳號沒有解鎖的購買紀錄。';

  @override
  String restoreFailed(String error) {
    return '恢復購買失敗:$error';
  }

  @override
  String get storeItemUnavailable => 'App Store 目前找不到這個品項。';

  @override
  String get storeUnverified => 'App Store 無法驗證這筆購買。';
}
