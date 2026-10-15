// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get close => 'Close';

  @override
  String get copy => 'Copy';

  @override
  String get clear => 'Clear';

  @override
  String get reset => 'Reset';

  @override
  String get refresh => 'Refresh';

  @override
  String get reconnect => 'Reconnect';

  @override
  String get settings => 'Settings';

  @override
  String get gotIt => 'Got it';

  @override
  String get unknownError => 'Unknown error';

  @override
  String get connecting => 'Connecting…';

  @override
  String get ended => 'Ended';

  @override
  String remotePath(String path) {
    return 'Remote: $path';
  }

  @override
  String get vaults => 'Vaults';

  @override
  String get hosts => 'Hosts';

  @override
  String get keys => 'Keys';

  @override
  String get vaultsTooltip => 'Vaults (Hosts / Keys)';

  @override
  String get vaultsTooltipMobile => 'Vaults (manage hosts and keys)';

  @override
  String get vaultOpenFailedTitle => 'Couldn\'t open the vault';

  @override
  String vaultOpenFailed(String error) {
    return 'Couldn\'t open the vault: $error';
  }

  @override
  String tabTitleDefault(int id) {
    return 'Terminal $id';
  }

  @override
  String tabTitleConnecting(String title) {
    return '$title (connecting…)';
  }

  @override
  String tabTitleEnded(String title) {
    return '$title (ended)';
  }

  @override
  String get newTabTooltip => 'New tab (Ctrl+Shift+T)';

  @override
  String get closeTabTooltip => 'Close (Ctrl+Shift+W)';

  @override
  String get closeTab => 'Close tab';

  @override
  String get filesPanelTooltip => 'File browser';

  @override
  String get localTerminal => 'Local terminal';

  @override
  String get noLocalShell => 'No local shell';

  @override
  String get connectionFailed => 'Connection failed';

  @override
  String get wheelCaptured => 'Wheel captured by app';

  @override
  String get wheelCapturedTooltip =>
      'The running program has taken over the mouse wheel (full-screen app or mouse reporting mode).\nIf it was killed before it could clean up, press “Reset terminal” to get scrolling back.';

  @override
  String get resetTerminal => 'Reset terminal';

  @override
  String get restartingTerminal => 'Restarting terminal…';

  @override
  String connectingTo(String name) {
    return 'Connecting to $name…';
  }

  @override
  String get localShellUnavailable => 'Local shells aren\'t available on iOS.';

  @override
  String get openVaultsForSsh => 'Open Vaults to connect over SSH';

  @override
  String terminalStartFailed(String error) {
    return 'Couldn\'t start the terminal\n\n$error';
  }

  @override
  String localShellFailed(String error) {
    return 'Couldn\'t start a shell: $error';
  }

  @override
  String get sshConnectFailed => 'SSH connection failed';

  @override
  String get reconnectTitle => 'Reconnect?';

  @override
  String reconnectBody(String title) {
    return 'This will drop the current connection to “$title” and open a new one.';
  }

  @override
  String get cwdNotFound => 'Couldn\'t tell which directory the terminal is in';

  @override
  String get vscodeNoRemoteInfo =>
      'Couldn\'t get the connection details for this host, so VS Code can\'t open it';

  @override
  String get vscodeNotFound =>
      'Couldn\'t find VS Code (code). Make sure it\'s installed and on your PATH.';

  @override
  String get discardEditsTitle => 'Discard unsaved changes?';

  @override
  String discardEditsBody(String file) {
    return '$file has unsaved changes.';
  }

  @override
  String get discard => 'Discard';

  @override
  String get dragOutTooLarge =>
      'This file is too big to drag out. Open it in the editor and save a copy from there.';

  @override
  String readRemoteFileFailed(String error) {
    return 'Couldn\'t read the remote file: $error';
  }

  @override
  String filesUploaded(int count, String dir) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Uploaded $count files to $dir',
      one: 'Uploaded 1 file to $dir',
    );
    return '$_temp0';
  }

  @override
  String filesCopied(int count, String dir) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copied $count files to $dir',
      one: 'Copied 1 file to $dir',
    );
    return '$_temp0';
  }

  @override
  String filesUploadedPartly(int count, String skipped) {
    return 'Uploaded $count, skipped: $skipped';
  }

  @override
  String filesCopiedPartly(int count, String skipped) {
    return 'Copied $count, skipped: $skipped';
  }

  @override
  String skippedFolder(String name) {
    return '$name (folder)';
  }

  @override
  String skippedTooLarge(String name) {
    return '$name (too large)';
  }

  @override
  String skippedWithReason(String name, String reason) {
    return '$name ($reason)';
  }

  @override
  String get keyHookUnknownTool => 'a background dictation or macro tool';

  @override
  String keyHookTool(String tool) {
    return '$tool (currently running)';
  }

  @override
  String keyHookWarning(String who) {
    return 'Your space key may be getting swallowed by a system-wide keyboard hook: you just typed a lot of characters without a single space. This usually happens when $who has a hotkey that includes Space. It has to hold on to every space press to see whether a shortcut follows, and once it gets stuck it never lets them through. Restarting that tool or changing its hotkey fixes it. Those key presses never reach the terminal, so this isn\'t a terminal bug.';
  }

  @override
  String deleteConfirm(String name) {
    return 'Delete “$name”? It\'ll be removed from all your synced devices too.';
  }

  @override
  String get hostSearchHint => 'Search by name, address, user, or note';

  @override
  String get addHost => 'Add Host';

  @override
  String get editHost => 'Edit Host';

  @override
  String hostCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hosts',
      one: '1 host',
    );
    return '$_temp0';
  }

  @override
  String hostCountFiltered(int shown, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$shown of $total hosts',
      one: '$shown of 1 host',
    );
    return '$_temp0';
  }

  @override
  String get hostsEmpty => 'No hosts yet. Hit “Add Host” to get started.';

  @override
  String get hostsNoMatch => 'No hosts match your search';

  @override
  String get keyDeleted => '(key deleted)';

  @override
  String hostKeyName(String name) {
    return 'Key: $name';
  }

  @override
  String get pin => 'Pin to top';

  @override
  String get unpin => 'Unpin';

  @override
  String get sshConnect => 'Connect over SSH';

  @override
  String get nameRequiredLabel => 'Name *';

  @override
  String get addressRequiredLabel => 'Address *';

  @override
  String get port => 'Port';

  @override
  String get username => 'Username';

  @override
  String get authMethod => 'Authentication';

  @override
  String get password => 'Password';

  @override
  String get sshKey => 'SSH key';

  @override
  String get authNone => 'None (interactive)';

  @override
  String get key => 'Key';

  @override
  String get note => 'Note';

  @override
  String get hostRequiredFields => 'Name and address are required';

  @override
  String get sshKeyMissing => 'This host\'s SSH key no longer exists';

  @override
  String keyCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count keys',
      one: '1 key',
    );
    return '$_temp0';
  }

  @override
  String get addKey => 'Add Key';

  @override
  String get keysEmpty =>
      'No keys yet. Hit “Generate Key” to make a new one, or “Add Key” to paste in a private key you already have.';

  @override
  String get addSshKey => 'Add SSH Key';

  @override
  String get editSshKey => 'Edit SSH Key';

  @override
  String get privateKeyRequiredLabel => 'Private key (paste OpenSSH or PEM) *';

  @override
  String get passphraseOptionalLabel => 'Passphrase (optional)';

  @override
  String get keyRequiredFields => 'Name and private key are required';

  @override
  String get publicKeyCopied =>
      'Public key copied. Paste it into ~/.ssh/authorized_keys on the server.';

  @override
  String publicKeyFailed(String error) {
    return 'Couldn\'t get the public key: $error';
  }

  @override
  String get publicKeyPending => 'Working out the public key…';

  @override
  String get copyPublicKey => 'Copy public key';

  @override
  String publicKeyWithFingerprint(String fingerprint) {
    return 'Public key ($fingerprint)';
  }

  @override
  String deleteFailed(String error) {
    return 'Couldn\'t delete: $error';
  }

  @override
  String get generateKey => 'Generate Key';

  @override
  String get generateSshKey => 'Generate SSH Key';

  @override
  String get keyType => 'Type';

  @override
  String get keyTypeEd25519 => 'Ed25519 (recommended)';

  @override
  String get keyTypeRsa => 'RSA 4096 (for older servers)';

  @override
  String get passphraseRepeatLabel => 'Repeat passphrase';

  @override
  String get keygenPassphraseHint =>
      'Leave empty for no passphrase. If you set one, the private key is encrypted with it; the passphrase is saved with the key in your vault and used automatically when connecting.';

  @override
  String get passphraseMismatch => 'The two passphrases don\'t match';

  @override
  String get keygenNameRequired => 'Name is required';

  @override
  String get generate => 'Generate';

  @override
  String get generatingKey => 'Generating…';

  @override
  String get keyGenerated => 'Key generated';

  @override
  String keyGeneratedBody(String name) {
    return 'Saved to Keys as “$name”. Add this public key to ~/.ssh/authorized_keys on the server, then pick this key for the host to sign in with it.';
  }

  @override
  String keygenFailed(String error) {
    return 'Couldn\'t generate the key: $error';
  }

  @override
  String get done => 'Done';

  @override
  String get undo => 'Undo';

  @override
  String get hostFingerprint => 'Host key fingerprint';

  @override
  String get hostFingerprintNone =>
      'Not remembered yet. The server\'s host key fingerprint is saved on the first connection and checked every time after that.';

  @override
  String get hostFingerprintClearHint =>
      'Only clear it if the server was reinstalled or its host key was replaced. After clearing, the next connection trusts whatever key the server presents and remembers it.';

  @override
  String get hostFingerprintWillClear =>
      'Will be cleared when you save. The next connection remembers the key the server presents.';

  @override
  String get hostFingerprintAddressChanged =>
      'The address or port changed, so the remembered fingerprint (it belongs to the old host) will be cleared when you save.';

  @override
  String get hostKeyChangedTitle => 'The host key has changed';

  @override
  String hostKeyChangedBody(String name) {
    return '“$name” presented a different host key from the one remembered on the first connection, so the connection was stopped.\n\nThe server may have been reinstalled, or its admin replaced the host key. But someone could also be intercepting this connection (a man-in-the-middle attack). Don\'t go on until you\'ve checked.';
  }

  @override
  String get hostKeyRemembered => 'Remembered fingerprint';

  @override
  String get hostKeyPresented => 'Fingerprint presented this time';

  @override
  String get hostKeyHowToVerify =>
      'To check: ask the server\'s admin to run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server and compare the result with the fingerprint presented this time. They have to match exactly.';

  @override
  String get hostKeyTrustNew =>
      'I\'ve confirmed the host changed. Use the new fingerprint…';

  @override
  String get hostKeyNotInVault =>
      'This host is no longer in your Vaults, so its fingerprint can\'t be updated here.';

  @override
  String get hostKeyTrustTitle => 'Use the new host key?';

  @override
  String hostKeyTrustBody(String name) {
    return 'From now on only this new key will be accepted for “$name”, and the old fingerprint is forgotten. If someone is in fact intercepting the connection, they could read everything you send after this, passwords included.';
  }

  @override
  String get hostKeyTrustCheckbox =>
      'I checked the new fingerprint through another channel, and it matches exactly';

  @override
  String get hostKeyTrustConfirm => 'Use new fingerprint and reconnect';

  @override
  String get tabBarPosition => 'Tab bar position';

  @override
  String get tabBarTop => 'Top (horizontal)';

  @override
  String get tabBarSide => 'Side (vertical list)';

  @override
  String get terminalFontSize => 'Terminal font size';

  @override
  String get fontSmaller => 'Smaller';

  @override
  String get fontLarger => 'Larger';

  @override
  String get fontSizeHint =>
      'In the terminal you can also use Ctrl +/-, Ctrl 0, or Ctrl + scroll wheel.';

  @override
  String get syncSection => 'Sync (self-hosted server)';

  @override
  String get syncNotConfigured =>
      'Sync isn\'t set up yet. Start it from this device, or paste a pairing string exported from another one.';

  @override
  String get syncServerLabel => 'Sync server address';

  @override
  String get setUpSync => 'Set up sync';

  @override
  String get joinWithPairing => 'Join with a pairing string';

  @override
  String get syncing => 'Syncing…';

  @override
  String syncFailed(String error) {
    return 'Sync failed: $error';
  }

  @override
  String lastSynced(String time) {
    return 'Last synced $time';
  }

  @override
  String get notSyncedYet => 'Not synced yet';

  @override
  String pendingChanges(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes waiting to upload',
      one: '1 change waiting to upload',
    );
    return '$_temp0';
  }

  @override
  String get syncNow => 'Sync now';

  @override
  String get exportPairing => 'Export pairing string';

  @override
  String get turnOffSync => 'Turn off sync';

  @override
  String get pastePairingTitle => 'Paste pairing string';

  @override
  String get join => 'Join';

  @override
  String joinedVault(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Joined the vault and merged in $count items from this device.',
      one: 'Joined the vault and merged in 1 item from this device.',
      zero: 'Joined the vault.',
    );
    return '$_temp0';
  }

  @override
  String get pairingStringTitle => 'Pairing string';

  @override
  String get pairingWarning =>
      '⚠️ This string contains your sync server address, auth token, and encryption key. Anyone who has it can read and change everything in this vault, so only pass it between your own devices.';

  @override
  String get turnOffSyncBody =>
      'This only disconnects from the server. Everything on this device stays as it is. Turn off sync?';

  @override
  String get turnOff => 'Turn off';

  @override
  String turnOffSyncFailed(String error) {
    return 'Couldn\'t turn off sync: $error';
  }

  @override
  String get serverAddressEmpty => 'Enter a server address';

  @override
  String syncServerResponded(int status, String message) {
    return 'Server responded $status: $message';
  }

  @override
  String get syncUnauthorized =>
      'The sync server didn\'t accept this device\'s credentials. You may need to pair it again.';

  @override
  String get syncVaultNotFound =>
      'The sync server doesn\'t have this vault anymore.';

  @override
  String get syncVaultConflict =>
      'This vault is already registered on the sync server with different credentials.';

  @override
  String conflictCopyName(String name, String device, String time) {
    return '$name (conflicted copy $device @$time)';
  }

  @override
  String get activeSessions => 'Active';

  @override
  String get mobileNoHosts =>
      'No hosts yet. Tap ⛁ in the top-right corner to open Vaults and add an SSH host.';

  @override
  String get pickConnectionHint => 'Pick a connection or a host on the left';

  @override
  String get sessionConnected => 'Connected';

  @override
  String get disconnectAndRemove => 'Disconnect and remove';

  @override
  String get connections => 'Connections';

  @override
  String get hideConnectionList => 'Hide connection list';

  @override
  String get showConnectionList => 'Show connection list';

  @override
  String get disconnect => 'Disconnect';

  @override
  String connectFailedBody(String error) {
    return 'Couldn\'t connect\n\n$error';
  }

  @override
  String get tapToType => 'Tap here to type';

  @override
  String get readOnlyTooLarge => 'Over 5 MB, read-only preview';

  @override
  String get readOnlyBinary => 'Binary file, can\'t be edited';

  @override
  String get savedRemote => 'Saved (remote)';

  @override
  String get saved => 'Saved';

  @override
  String saveFailed(String error) {
    return 'Couldn\'t save: $error';
  }

  @override
  String linkOpenFailed(String url) {
    return 'Couldn\'t open this link: $url';
  }

  @override
  String get fileChangedTitle => 'File changed on disk';

  @override
  String get fileChangedBody =>
      'Another program changed this file while you were editing it. Overwrite it with your version?';

  @override
  String get overwrite => 'Overwrite';

  @override
  String get showSource => 'Show source';

  @override
  String get previewMarkdown => 'Preview Markdown';

  @override
  String get saveTooltip => 'Save (Ctrl+S)';

  @override
  String get closeEscTooltip => 'Close (Esc)';

  @override
  String fileOpenFailed(String error) {
    return 'Couldn\'t open this file\n$error';
  }

  @override
  String get openInVscode => 'Open in VS Code';

  @override
  String get parentFolder => 'Up one level';

  @override
  String get jumpToCwd =>
      'Go to the terminal\'s current directory (active tab)';

  @override
  String get followCwdOn => 'Follow terminal directory (on)';

  @override
  String get followCwdOff => 'Follow terminal directory (off)';

  @override
  String listDirFailed(String error) {
    return 'Couldn\'t read this folder\n$error';
  }

  @override
  String get emptyFolder => '(empty folder)';

  @override
  String errHostKeyMismatch(String expected, String actual) {
    return 'Host key mismatch! Expected $expected, but the server presented $actual. The connection was stopped: someone may be intercepting it, or the server\'s host key has changed.';
  }

  @override
  String errTimeout(String op) {
    String _temp0 = intl.Intl.selectLogic(op, {
      'list_dir':
          'Listing the folder over SFTP timed out (the connection may be down)',
      'home':
          'Finding the home folder over SFTP timed out (the connection may be down)',
      'read_file':
          'Reading the file over SFTP timed out (the connection may be down)',
      'write_file':
          'Writing the file over SFTP timed out (the connection may be down)',
      'exec': 'The remote command timed out',
      'other': 'Timed out (the connection may be down)',
    });
    return '$_temp0';
  }

  @override
  String errPrivateKeyUnreadable(String reason) {
    return 'Can\'t read this private key: $reason';
  }

  @override
  String get errPairingMissingPrefix =>
      'This isn\'t a tterminal pairing string (it should start with TTERMSYNC1:).';

  @override
  String errPairingUnsupportedVersion(int version) {
    return 'This pairing string is version $version, but this version of tterminal only reads v1.';
  }

  @override
  String get errPairingMalformed =>
      'This pairing string is incomplete or damaged. Try copying it again.';

  @override
  String get errDecryptFailed =>
      'Couldn\'t decrypt the data (wrong key, or it\'s been tampered with).';
}
