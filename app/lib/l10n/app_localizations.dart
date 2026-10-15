import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @reconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get reconnect;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @gotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// No description provided for @unknownError.
  ///
  /// In en, this message translates to:
  /// **'Unknown error'**
  String get unknownError;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connecting;

  /// No description provided for @ended.
  ///
  /// In en, this message translates to:
  /// **'Ended'**
  String get ended;

  /// Tooltip for a path on the SSH host (file browser, editor).
  ///
  /// In en, this message translates to:
  /// **'Remote: {path}'**
  String remotePath(String path);

  /// No description provided for @vaults.
  ///
  /// In en, this message translates to:
  /// **'Vaults'**
  String get vaults;

  /// No description provided for @hosts.
  ///
  /// In en, this message translates to:
  /// **'Hosts'**
  String get hosts;

  /// No description provided for @keys.
  ///
  /// In en, this message translates to:
  /// **'Keys'**
  String get keys;

  /// No description provided for @vaultsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Vaults (Hosts / Keys)'**
  String get vaultsTooltip;

  /// No description provided for @vaultsTooltipMobile.
  ///
  /// In en, this message translates to:
  /// **'Vaults (manage hosts and keys)'**
  String get vaultsTooltipMobile;

  /// No description provided for @vaultOpenFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the vault'**
  String get vaultOpenFailedTitle;

  /// No description provided for @vaultOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the vault: {error}'**
  String vaultOpenFailed(String error);

  /// Tab title before the shell sets one.
  ///
  /// In en, this message translates to:
  /// **'Terminal {id}'**
  String tabTitleDefault(int id);

  /// No description provided for @tabTitleConnecting.
  ///
  /// In en, this message translates to:
  /// **'{title} (connecting…)'**
  String tabTitleConnecting(String title);

  /// No description provided for @tabTitleEnded.
  ///
  /// In en, this message translates to:
  /// **'{title} (ended)'**
  String tabTitleEnded(String title);

  /// No description provided for @newTabTooltip.
  ///
  /// In en, this message translates to:
  /// **'New tab (Ctrl+Shift+T)'**
  String get newTabTooltip;

  /// No description provided for @closeTabTooltip.
  ///
  /// In en, this message translates to:
  /// **'Close (Ctrl+Shift+W)'**
  String get closeTabTooltip;

  /// No description provided for @closeTab.
  ///
  /// In en, this message translates to:
  /// **'Close tab'**
  String get closeTab;

  /// No description provided for @filesPanelTooltip.
  ///
  /// In en, this message translates to:
  /// **'File browser'**
  String get filesPanelTooltip;

  /// No description provided for @localTerminal.
  ///
  /// In en, this message translates to:
  /// **'Local terminal'**
  String get localTerminal;

  /// No description provided for @noLocalShell.
  ///
  /// In en, this message translates to:
  /// **'No local shell'**
  String get noLocalShell;

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailed;

  /// No description provided for @wheelCaptured.
  ///
  /// In en, this message translates to:
  /// **'Wheel captured by app'**
  String get wheelCaptured;

  /// No description provided for @wheelCapturedTooltip.
  ///
  /// In en, this message translates to:
  /// **'The running program has taken over the mouse wheel (full-screen app or mouse reporting mode).\nIf it was killed before it could clean up, press “Reset terminal” to get scrolling back.'**
  String get wheelCapturedTooltip;

  /// No description provided for @resetTerminal.
  ///
  /// In en, this message translates to:
  /// **'Reset terminal'**
  String get resetTerminal;

  /// No description provided for @restartingTerminal.
  ///
  /// In en, this message translates to:
  /// **'Restarting terminal…'**
  String get restartingTerminal;

  /// No description provided for @connectingTo.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {name}…'**
  String connectingTo(String name);

  /// No description provided for @localShellUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Local shells aren\'t available on iOS.'**
  String get localShellUnavailable;

  /// No description provided for @openVaultsForSsh.
  ///
  /// In en, this message translates to:
  /// **'Open Vaults to connect over SSH'**
  String get openVaultsForSsh;

  /// No description provided for @terminalStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start the terminal\n\n{error}'**
  String terminalStartFailed(String error);

  /// No description provided for @localShellFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start a shell: {error}'**
  String localShellFailed(String error);

  /// No description provided for @sshConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'SSH connection failed'**
  String get sshConnectFailed;

  /// No description provided for @reconnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Reconnect?'**
  String get reconnectTitle;

  /// No description provided for @reconnectBody.
  ///
  /// In en, this message translates to:
  /// **'This will drop the current connection to “{title}” and open a new one.'**
  String reconnectBody(String title);

  /// No description provided for @cwdNotFound.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t tell which directory the terminal is in'**
  String get cwdNotFound;

  /// No description provided for @vscodeNoRemoteInfo.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t get the connection details for this host, so VS Code can\'t open it'**
  String get vscodeNoRemoteInfo;

  /// No description provided for @vscodeNotFound.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t find VS Code (code). Make sure it\'s installed and on your PATH.'**
  String get vscodeNotFound;

  /// No description provided for @discardEditsTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard unsaved changes?'**
  String get discardEditsTitle;

  /// No description provided for @discardEditsBody.
  ///
  /// In en, this message translates to:
  /// **'{file} has unsaved changes.'**
  String discardEditsBody(String file);

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @dragOutTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This file is too big to drag out. Open it in the editor and save a copy from there.'**
  String get dragOutTooLarge;

  /// No description provided for @readRemoteFileFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the remote file: {error}'**
  String readRemoteFileFailed(String error);

  /// Files dropped onto the file browser while it shows an SSH host.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Uploaded 1 file to {dir}} other{Uploaded {count} files to {dir}}}'**
  String filesUploaded(int count, String dir);

  /// No description provided for @filesCopied.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Copied 1 file to {dir}} other{Copied {count} files to {dir}}}'**
  String filesCopied(int count, String dir);

  /// No description provided for @filesUploadedPartly.
  ///
  /// In en, this message translates to:
  /// **'Uploaded {count}, skipped: {skipped}'**
  String filesUploadedPartly(int count, String skipped);

  /// No description provided for @filesCopiedPartly.
  ///
  /// In en, this message translates to:
  /// **'Copied {count}, skipped: {skipped}'**
  String filesCopiedPartly(int count, String skipped);

  /// No description provided for @skippedFolder.
  ///
  /// In en, this message translates to:
  /// **'{name} (folder)'**
  String skippedFolder(String name);

  /// No description provided for @skippedTooLarge.
  ///
  /// In en, this message translates to:
  /// **'{name} (too large)'**
  String skippedTooLarge(String name);

  /// No description provided for @skippedWithReason.
  ///
  /// In en, this message translates to:
  /// **'{name} ({reason})'**
  String skippedWithReason(String name, String reason);

  /// No description provided for @keyHookUnknownTool.
  ///
  /// In en, this message translates to:
  /// **'a background dictation or macro tool'**
  String get keyHookUnknownTool;

  /// No description provided for @keyHookTool.
  ///
  /// In en, this message translates to:
  /// **'{tool} (currently running)'**
  String keyHookTool(String tool);

  /// {who} is keyHookUnknownTool or keyHookTool.
  ///
  /// In en, this message translates to:
  /// **'Your space key may be getting swallowed by a system-wide keyboard hook: you just typed a lot of characters without a single space. This usually happens when {who} has a hotkey that includes Space. It has to hold on to every space press to see whether a shortcut follows, and once it gets stuck it never lets them through. Restarting that tool or changing its hotkey fixes it. Those key presses never reach the terminal, so this isn\'t a terminal bug.'**
  String keyHookWarning(String who);

  /// No description provided for @deleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}”? It\'ll be removed from all your synced devices too.'**
  String deleteConfirm(String name);

  /// No description provided for @hostSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search by name, address, user, or note'**
  String get hostSearchHint;

  /// No description provided for @addHost.
  ///
  /// In en, this message translates to:
  /// **'Add Host'**
  String get addHost;

  /// No description provided for @editHost.
  ///
  /// In en, this message translates to:
  /// **'Edit Host'**
  String get editHost;

  /// No description provided for @hostCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 host} other{{count} hosts}}'**
  String hostCount(int count);

  /// No description provided for @hostCountFiltered.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{{shown} of 1 host} other{{shown} of {total} hosts}}'**
  String hostCountFiltered(int shown, int total);

  /// No description provided for @hostsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No hosts yet. Hit “Add Host” to get started.'**
  String get hostsEmpty;

  /// No description provided for @hostsNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No hosts match your search'**
  String get hostsNoMatch;

  /// No description provided for @keyDeleted.
  ///
  /// In en, this message translates to:
  /// **'(key deleted)'**
  String get keyDeleted;

  /// No description provided for @hostKeyName.
  ///
  /// In en, this message translates to:
  /// **'Key: {name}'**
  String hostKeyName(String name);

  /// No description provided for @pin.
  ///
  /// In en, this message translates to:
  /// **'Pin to top'**
  String get pin;

  /// No description provided for @unpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpin;

  /// No description provided for @sshConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect over SSH'**
  String get sshConnect;

  /// No description provided for @nameRequiredLabel.
  ///
  /// In en, this message translates to:
  /// **'Name *'**
  String get nameRequiredLabel;

  /// No description provided for @addressRequiredLabel.
  ///
  /// In en, this message translates to:
  /// **'Address *'**
  String get addressRequiredLabel;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @authMethod.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get authMethod;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @sshKey.
  ///
  /// In en, this message translates to:
  /// **'SSH key'**
  String get sshKey;

  /// No description provided for @authNone.
  ///
  /// In en, this message translates to:
  /// **'None (interactive)'**
  String get authNone;

  /// No description provided for @key.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get key;

  /// No description provided for @note.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get note;

  /// No description provided for @hostRequiredFields.
  ///
  /// In en, this message translates to:
  /// **'Name and address are required'**
  String get hostRequiredFields;

  /// No description provided for @sshKeyMissing.
  ///
  /// In en, this message translates to:
  /// **'This host\'s SSH key no longer exists'**
  String get sshKeyMissing;

  /// No description provided for @keyCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 key} other{{count} keys}}'**
  String keyCount(int count);

  /// No description provided for @addKey.
  ///
  /// In en, this message translates to:
  /// **'Add Key'**
  String get addKey;

  /// No description provided for @keysEmpty.
  ///
  /// In en, this message translates to:
  /// **'No keys yet. Hit “Generate Key” to make a new one, or “Add Key” to paste in a private key you already have.'**
  String get keysEmpty;

  /// No description provided for @addSshKey.
  ///
  /// In en, this message translates to:
  /// **'Add SSH Key'**
  String get addSshKey;

  /// No description provided for @editSshKey.
  ///
  /// In en, this message translates to:
  /// **'Edit SSH Key'**
  String get editSshKey;

  /// No description provided for @privateKeyRequiredLabel.
  ///
  /// In en, this message translates to:
  /// **'Private key (paste OpenSSH or PEM) *'**
  String get privateKeyRequiredLabel;

  /// No description provided for @passphraseOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'Passphrase (optional)'**
  String get passphraseOptionalLabel;

  /// No description provided for @keyRequiredFields.
  ///
  /// In en, this message translates to:
  /// **'Name and private key are required'**
  String get keyRequiredFields;

  /// No description provided for @publicKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Public key copied. Paste it into ~/.ssh/authorized_keys on the server.'**
  String get publicKeyCopied;

  /// No description provided for @publicKeyFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t get the public key: {error}'**
  String publicKeyFailed(String error);

  /// No description provided for @publicKeyPending.
  ///
  /// In en, this message translates to:
  /// **'Working out the public key…'**
  String get publicKeyPending;

  /// No description provided for @copyPublicKey.
  ///
  /// In en, this message translates to:
  /// **'Copy public key'**
  String get copyPublicKey;

  /// No description provided for @publicKeyWithFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Public key ({fingerprint})'**
  String publicKeyWithFingerprint(String fingerprint);

  /// No description provided for @deleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete: {error}'**
  String deleteFailed(String error);

  /// No description provided for @generateKey.
  ///
  /// In en, this message translates to:
  /// **'Generate Key'**
  String get generateKey;

  /// No description provided for @generateSshKey.
  ///
  /// In en, this message translates to:
  /// **'Generate SSH Key'**
  String get generateSshKey;

  /// No description provided for @keyType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get keyType;

  /// No description provided for @keyTypeEd25519.
  ///
  /// In en, this message translates to:
  /// **'Ed25519 (recommended)'**
  String get keyTypeEd25519;

  /// No description provided for @keyTypeRsa.
  ///
  /// In en, this message translates to:
  /// **'RSA 4096 (for older servers)'**
  String get keyTypeRsa;

  /// No description provided for @passphraseRepeatLabel.
  ///
  /// In en, this message translates to:
  /// **'Repeat passphrase'**
  String get passphraseRepeatLabel;

  /// No description provided for @keygenPassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for no passphrase. If you set one, the private key is encrypted with it; the passphrase is saved with the key in your vault and used automatically when connecting.'**
  String get keygenPassphraseHint;

  /// No description provided for @passphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'The two passphrases don\'t match'**
  String get passphraseMismatch;

  /// No description provided for @keygenNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get keygenNameRequired;

  /// No description provided for @generate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get generate;

  /// No description provided for @generatingKey.
  ///
  /// In en, this message translates to:
  /// **'Generating…'**
  String get generatingKey;

  /// No description provided for @keyGenerated.
  ///
  /// In en, this message translates to:
  /// **'Key generated'**
  String get keyGenerated;

  /// No description provided for @keyGeneratedBody.
  ///
  /// In en, this message translates to:
  /// **'Saved to Keys as “{name}”. Add this public key to ~/.ssh/authorized_keys on the server, then pick this key for the host to sign in with it.'**
  String keyGeneratedBody(String name);

  /// No description provided for @keygenFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t generate the key: {error}'**
  String keygenFailed(String error);

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @hostFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Host key fingerprint'**
  String get hostFingerprint;

  /// No description provided for @hostFingerprintNone.
  ///
  /// In en, this message translates to:
  /// **'Not remembered yet. The server\'s host key fingerprint is saved on the first connection and checked every time after that.'**
  String get hostFingerprintNone;

  /// No description provided for @hostFingerprintClearHint.
  ///
  /// In en, this message translates to:
  /// **'Only clear it if the server was reinstalled or its host key was replaced. After clearing, the next connection trusts whatever key the server presents and remembers it.'**
  String get hostFingerprintClearHint;

  /// No description provided for @hostFingerprintWillClear.
  ///
  /// In en, this message translates to:
  /// **'Will be cleared when you save. The next connection remembers the key the server presents.'**
  String get hostFingerprintWillClear;

  /// No description provided for @hostFingerprintAddressChanged.
  ///
  /// In en, this message translates to:
  /// **'The address or port changed, so the remembered fingerprint (it belongs to the old host) will be cleared when you save.'**
  String get hostFingerprintAddressChanged;

  /// No description provided for @hostKeyChangedTitle.
  ///
  /// In en, this message translates to:
  /// **'The host key has changed'**
  String get hostKeyChangedTitle;

  /// No description provided for @hostKeyChangedBody.
  ///
  /// In en, this message translates to:
  /// **'“{name}” presented a different host key from the one remembered on the first connection, so the connection was stopped.\n\nThe server may have been reinstalled, or its admin replaced the host key. But someone could also be intercepting this connection (a man-in-the-middle attack). Don\'t go on until you\'ve checked.'**
  String hostKeyChangedBody(String name);

  /// No description provided for @hostKeyRemembered.
  ///
  /// In en, this message translates to:
  /// **'Remembered fingerprint'**
  String get hostKeyRemembered;

  /// No description provided for @hostKeyPresented.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint presented this time'**
  String get hostKeyPresented;

  /// No description provided for @hostKeyHowToVerify.
  ///
  /// In en, this message translates to:
  /// **'To check: ask the server\'s admin to run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server and compare the result with the fingerprint presented this time. They have to match exactly.'**
  String get hostKeyHowToVerify;

  /// No description provided for @hostKeyTrustNew.
  ///
  /// In en, this message translates to:
  /// **'I\'ve confirmed the host changed. Use the new fingerprint…'**
  String get hostKeyTrustNew;

  /// No description provided for @hostKeyNotInVault.
  ///
  /// In en, this message translates to:
  /// **'This host is no longer in your Vaults, so its fingerprint can\'t be updated here.'**
  String get hostKeyNotInVault;

  /// No description provided for @hostKeyTrustTitle.
  ///
  /// In en, this message translates to:
  /// **'Use the new host key?'**
  String get hostKeyTrustTitle;

  /// No description provided for @hostKeyTrustBody.
  ///
  /// In en, this message translates to:
  /// **'From now on only this new key will be accepted for “{name}”, and the old fingerprint is forgotten. If someone is in fact intercepting the connection, they could read everything you send after this, passwords included.'**
  String hostKeyTrustBody(String name);

  /// No description provided for @hostKeyTrustCheckbox.
  ///
  /// In en, this message translates to:
  /// **'I checked the new fingerprint through another channel, and it matches exactly'**
  String get hostKeyTrustCheckbox;

  /// No description provided for @hostKeyTrustConfirm.
  ///
  /// In en, this message translates to:
  /// **'Use new fingerprint and reconnect'**
  String get hostKeyTrustConfirm;

  /// No description provided for @tabBarPosition.
  ///
  /// In en, this message translates to:
  /// **'Tab bar position'**
  String get tabBarPosition;

  /// No description provided for @tabBarTop.
  ///
  /// In en, this message translates to:
  /// **'Top (horizontal)'**
  String get tabBarTop;

  /// No description provided for @tabBarSide.
  ///
  /// In en, this message translates to:
  /// **'Side (vertical list)'**
  String get tabBarSide;

  /// No description provided for @terminalFontSize.
  ///
  /// In en, this message translates to:
  /// **'Terminal font size'**
  String get terminalFontSize;

  /// No description provided for @fontSmaller.
  ///
  /// In en, this message translates to:
  /// **'Smaller'**
  String get fontSmaller;

  /// No description provided for @fontLarger.
  ///
  /// In en, this message translates to:
  /// **'Larger'**
  String get fontLarger;

  /// No description provided for @fontSizeHint.
  ///
  /// In en, this message translates to:
  /// **'In the terminal you can also use Ctrl +/-, Ctrl 0, or Ctrl + scroll wheel.'**
  String get fontSizeHint;

  /// No description provided for @syncSection.
  ///
  /// In en, this message translates to:
  /// **'Sync (self-hosted server)'**
  String get syncSection;

  /// No description provided for @syncNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Sync isn\'t set up yet. Start it from this device, or paste a pairing string exported from another one.'**
  String get syncNotConfigured;

  /// No description provided for @syncServerLabel.
  ///
  /// In en, this message translates to:
  /// **'Sync server address'**
  String get syncServerLabel;

  /// No description provided for @setUpSync.
  ///
  /// In en, this message translates to:
  /// **'Set up sync'**
  String get setUpSync;

  /// No description provided for @joinWithPairing.
  ///
  /// In en, this message translates to:
  /// **'Join with a pairing string'**
  String get joinWithPairing;

  /// No description provided for @syncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncing;

  /// No description provided for @syncFailed.
  ///
  /// In en, this message translates to:
  /// **'Sync failed: {error}'**
  String syncFailed(String error);

  /// {time} is HH:mm:ss.
  ///
  /// In en, this message translates to:
  /// **'Last synced {time}'**
  String lastSynced(String time);

  /// No description provided for @notSyncedYet.
  ///
  /// In en, this message translates to:
  /// **'Not synced yet'**
  String get notSyncedYet;

  /// No description provided for @pendingChanges.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change waiting to upload} other{{count} changes waiting to upload}}'**
  String pendingChanges(int count);

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get syncNow;

  /// No description provided for @exportPairing.
  ///
  /// In en, this message translates to:
  /// **'Export pairing string'**
  String get exportPairing;

  /// No description provided for @turnOffSync.
  ///
  /// In en, this message translates to:
  /// **'Turn off sync'**
  String get turnOffSync;

  /// No description provided for @pastePairingTitle.
  ///
  /// In en, this message translates to:
  /// **'Paste pairing string'**
  String get pastePairingTitle;

  /// No description provided for @join.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get join;

  /// No description provided for @joinedVault.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Joined the vault.} =1{Joined the vault and merged in 1 item from this device.} other{Joined the vault and merged in {count} items from this device.}}'**
  String joinedVault(int count);

  /// No description provided for @pairingStringTitle.
  ///
  /// In en, this message translates to:
  /// **'Pairing string'**
  String get pairingStringTitle;

  /// No description provided for @pairingWarning.
  ///
  /// In en, this message translates to:
  /// **'⚠️ This string contains your sync server address, auth token, and encryption key. Anyone who has it can read and change everything in this vault, so only pass it between your own devices.'**
  String get pairingWarning;

  /// No description provided for @turnOffSyncBody.
  ///
  /// In en, this message translates to:
  /// **'This only disconnects from the server. Everything on this device stays as it is. Turn off sync?'**
  String get turnOffSyncBody;

  /// No description provided for @turnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get turnOff;

  /// No description provided for @turnOffSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t turn off sync: {error}'**
  String turnOffSyncFailed(String error);

  /// No description provided for @serverAddressEmpty.
  ///
  /// In en, this message translates to:
  /// **'Enter a server address'**
  String get serverAddressEmpty;

  /// No description provided for @syncServerResponded.
  ///
  /// In en, this message translates to:
  /// **'Server responded {status}: {message}'**
  String syncServerResponded(int status, String message);

  /// No description provided for @syncUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'The sync server didn\'t accept this device\'s credentials. You may need to pair it again.'**
  String get syncUnauthorized;

  /// No description provided for @syncVaultNotFound.
  ///
  /// In en, this message translates to:
  /// **'The sync server doesn\'t have this vault anymore.'**
  String get syncVaultNotFound;

  /// No description provided for @syncVaultConflict.
  ///
  /// In en, this message translates to:
  /// **'This vault is already registered on the sync server with different credentials.'**
  String get syncVaultConflict;

  /// Name given to the local version of a host/key when another device changed it at the same time. Rust fills in the placeholders.
  ///
  /// In en, this message translates to:
  /// **'{name} (conflicted copy {device} @{time})'**
  String conflictCopyName(String name, String device, String time);

  /// No description provided for @activeSessions.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get activeSessions;

  /// No description provided for @mobileNoHosts.
  ///
  /// In en, this message translates to:
  /// **'No hosts yet. Tap ⛁ in the top-right corner to open Vaults and add an SSH host.'**
  String get mobileNoHosts;

  /// No description provided for @pickConnectionHint.
  ///
  /// In en, this message translates to:
  /// **'Pick a connection or a host on the left'**
  String get pickConnectionHint;

  /// No description provided for @sessionConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get sessionConnected;

  /// No description provided for @disconnectAndRemove.
  ///
  /// In en, this message translates to:
  /// **'Disconnect and remove'**
  String get disconnectAndRemove;

  /// No description provided for @connections.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get connections;

  /// No description provided for @hideConnectionList.
  ///
  /// In en, this message translates to:
  /// **'Hide connection list'**
  String get hideConnectionList;

  /// No description provided for @showConnectionList.
  ///
  /// In en, this message translates to:
  /// **'Show connection list'**
  String get showConnectionList;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @connectFailedBody.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t connect\n\n{error}'**
  String connectFailedBody(String error);

  /// No description provided for @tapToType.
  ///
  /// In en, this message translates to:
  /// **'Tap here to type'**
  String get tapToType;

  /// No description provided for @readOnlyTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Over 5 MB, read-only preview'**
  String get readOnlyTooLarge;

  /// No description provided for @readOnlyBinary.
  ///
  /// In en, this message translates to:
  /// **'Binary file, can\'t be edited'**
  String get readOnlyBinary;

  /// No description provided for @savedRemote.
  ///
  /// In en, this message translates to:
  /// **'Saved (remote)'**
  String get savedRemote;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save: {error}'**
  String saveFailed(String error);

  /// No description provided for @linkOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open this link: {url}'**
  String linkOpenFailed(String url);

  /// No description provided for @fileChangedTitle.
  ///
  /// In en, this message translates to:
  /// **'File changed on disk'**
  String get fileChangedTitle;

  /// No description provided for @fileChangedBody.
  ///
  /// In en, this message translates to:
  /// **'Another program changed this file while you were editing it. Overwrite it with your version?'**
  String get fileChangedBody;

  /// No description provided for @overwrite.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get overwrite;

  /// No description provided for @showSource.
  ///
  /// In en, this message translates to:
  /// **'Show source'**
  String get showSource;

  /// No description provided for @previewMarkdown.
  ///
  /// In en, this message translates to:
  /// **'Preview Markdown'**
  String get previewMarkdown;

  /// No description provided for @saveTooltip.
  ///
  /// In en, this message translates to:
  /// **'Save (Ctrl+S)'**
  String get saveTooltip;

  /// No description provided for @closeEscTooltip.
  ///
  /// In en, this message translates to:
  /// **'Close (Esc)'**
  String get closeEscTooltip;

  /// No description provided for @fileOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open this file\n{error}'**
  String fileOpenFailed(String error);

  /// No description provided for @openInVscode.
  ///
  /// In en, this message translates to:
  /// **'Open in VS Code'**
  String get openInVscode;

  /// No description provided for @parentFolder.
  ///
  /// In en, this message translates to:
  /// **'Up one level'**
  String get parentFolder;

  /// No description provided for @jumpToCwd.
  ///
  /// In en, this message translates to:
  /// **'Go to the terminal\'s current directory (active tab)'**
  String get jumpToCwd;

  /// No description provided for @followCwdOn.
  ///
  /// In en, this message translates to:
  /// **'Follow terminal directory (on)'**
  String get followCwdOn;

  /// No description provided for @followCwdOff.
  ///
  /// In en, this message translates to:
  /// **'Follow terminal directory (off)'**
  String get followCwdOff;

  /// No description provided for @listDirFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read this folder\n{error}'**
  String listDirFailed(String error);

  /// No description provided for @emptyFolder.
  ///
  /// In en, this message translates to:
  /// **'(empty folder)'**
  String get emptyFolder;

  /// Rust error code host_key_mismatch.
  ///
  /// In en, this message translates to:
  /// **'Host key mismatch! Expected {expected}, but the server presented {actual}. The connection was stopped: someone may be intercepting it, or the server\'s host key has changed.'**
  String errHostKeyMismatch(String expected, String actual);

  /// Rust error code timeout; op says which operation.
  ///
  /// In en, this message translates to:
  /// **'{op, select, list_dir{Listing the folder over SFTP timed out (the connection may be down)} home{Finding the home folder over SFTP timed out (the connection may be down)} read_file{Reading the file over SFTP timed out (the connection may be down)} write_file{Writing the file over SFTP timed out (the connection may be down)} exec{The remote command timed out} other{Timed out (the connection may be down)}}'**
  String errTimeout(String op);

  /// Rust error code private_key_unreadable; reason comes from the SSH library (English).
  ///
  /// In en, this message translates to:
  /// **'Can\'t read this private key: {reason}'**
  String errPrivateKeyUnreadable(String reason);

  /// No description provided for @errPairingMissingPrefix.
  ///
  /// In en, this message translates to:
  /// **'This isn\'t a tterminal pairing string (it should start with TTERMSYNC1:).'**
  String get errPairingMissingPrefix;

  /// No description provided for @errPairingUnsupportedVersion.
  ///
  /// In en, this message translates to:
  /// **'This pairing string is version {version}, but this version of tterminal only reads v1.'**
  String errPairingUnsupportedVersion(int version);

  /// No description provided for @errPairingMalformed.
  ///
  /// In en, this message translates to:
  /// **'This pairing string is incomplete or damaged. Try copying it again.'**
  String get errPairingMalformed;

  /// No description provided for @errDecryptFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t decrypt the data (wrong key, or it\'s been tampered with).'**
  String get errDecryptFailed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
