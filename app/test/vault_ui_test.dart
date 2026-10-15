// Vaults 頁(Hosts/Keys CRUD、主機指紋、產生金鑰)與設定頁(分頁位置、配對匯入匯出)
// widget 測試。
// VaultService 用真 FFI + 暫存目錄。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tterm_app/src/prefs.dart';
import 'package:tterm_app/src/settings_page.dart';
import 'package:tterm_app/src/term_ffi.dart';
import 'package:tterm_app/src/vault_pages.dart';
import 'package:tterm_app/src/vault_service.dart';

void main() {
  late Directory tmp;
  late VaultService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tterm-vault-ui');
    service = VaultService.open('${tmp.path}/vault');
  });

  tearDown(() async {
    service.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpVaults(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VaultsPage(service: service),
      ),
    );
    await tester.pump();
  }

  testWidgets('Host CRUD:新增 → 列表 → 編輯 → 刪除', (tester) async {
    await pumpVaults(tester);
    expect(find.textContaining('還沒有主機'), findsOneWidget);

    // 新增
    await tester.tap(find.byKey(const Key('btn-add-host')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('host-name')), 'web1');
    await tester.enterText(find.byKey(const Key('host-address')), '10.0.0.5');
    await tester.enterText(find.byKey(const Key('host-port')), '2222');
    await tester.enterText(find.byKey(const Key('host-username')), 'root');
    await tester.enterText(find.byKey(const Key('host-password')), 'pw');
    await tester.tap(find.byKey(const Key('btn-save-host')));
    await tester.pumpAndSettle();

    expect(find.text('web1'), findsOneWidget);
    expect(find.textContaining('root@10.0.0.5:2222'), findsOneWidget);
    final host = service.hosts.single;
    expect(host.data['auth']['password'], 'pw');

    // 編輯(點列表項打開、改名)
    await tester.tap(find.text('web1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('host-name')), 'web1-renamed');
    await tester.tap(find.byKey(const Key('btn-save-host')));
    await tester.pumpAndSettle();
    expect(find.text('web1-renamed'), findsOneWidget);
    expect(service.hosts.length, 1, reason: '編輯不是新增');

    // 刪除(確認 dialog)
    await tester.tap(find.byKey(ValueKey('btn-delete-host-${host.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-confirm-delete')));
    await tester.pumpAndSettle();
    expect(service.hosts, isEmpty);
  });

  testWidgets('Host 搜尋 filter + 星號置頂', (tester) async {
    String addHost(String name, String address, String user, {String? note}) =>
        service.upsert(kind: 'host', name: name, data: {
          'address': address,
          'port': 22,
          'username': user,
          'auth': {'method': 'password'},
          'note': ?note,
        });
    final webId = addHost('web1', '10.0.0.1', 'root');
    final dbId = addHost('db1', '10.0.0.2', 'admin', note: '正式庫');
    addHost('app2', '192.168.1.9', 'deploy');

    List<String> visibleNames() => [
          for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
            (t.title as Text).data!,
        ];

    await pumpVaults(tester);
    // snapshot 依名稱排序
    expect(visibleNames(), ['app2', 'db1', 'web1']);
    expect(find.text('3 台主機'), findsOneWidget);

    // 搜尋名稱
    await tester.enterText(find.byKey(const Key('host-search')), 'db');
    await tester.pump();
    expect(visibleNames(), ['db1']);
    expect(find.text('1 / 3 台主機'), findsOneWidget);

    // 搜尋備註、位址、使用者
    await tester.enterText(find.byKey(const Key('host-search')), '正式');
    await tester.pump();
    expect(visibleNames(), ['db1']);
    await tester.enterText(find.byKey(const Key('host-search')), '192.168');
    await tester.pump();
    expect(visibleNames(), ['app2']);
    await tester.enterText(find.byKey(const Key('host-search')), 'ROOT');
    await tester.pump();
    expect(visibleNames(), ['web1'], reason: '不分大小寫');

    // 沒有結果
    await tester.enterText(find.byKey(const Key('host-search')), 'xxx');
    await tester.pump();
    expect(find.text('沒有符合搜尋的主機'), findsOneWidget);

    // 清除鈕還原
    await tester.tap(find.byKey(const Key('btn-clear-host-search')));
    await tester.pump();
    expect(visibleNames(), ['app2', 'db1', 'web1']);

    // 置頂 web1 → 排最前,資料寫入 pinned
    await tester.tap(find.byKey(ValueKey('btn-pin-host-$webId')));
    await tester.pump();
    expect(visibleNames(), ['web1', 'app2', 'db1']);
    expect(service.byId(webId)!.data['pinned'], isTrue);

    // 再置頂 db1 → 置頂群組內仍依名稱排序
    await tester.tap(find.byKey(ValueKey('btn-pin-host-$dbId')));
    await tester.pump();
    expect(visibleNames(), ['db1', 'web1', 'app2']);

    // 取消置頂 web1 → 回到未置頂區,pinned 鍵移除
    await tester.tap(find.byKey(ValueKey('btn-pin-host-$webId')));
    await tester.pump();
    expect(visibleNames(), ['db1', 'app2', 'web1']);
    expect(service.byId(webId)!.data.containsKey('pinned'), isFalse);

    // 搜尋時置頂排序也生效(db1 置頂中)
    await tester.enterText(find.byKey(const Key('host-search')), '10.0.0');
    await tester.pump();
    expect(visibleNames(), ['db1', 'web1']);
  });

  testWidgets('編輯 Host 不會弄丟 pinned 與 auth 裡保留的密碼', (tester) async {
    final id = service.upsert(kind: 'host', name: 'srv', data: {
      'address': '10.0.0.9',
      'port': 22,
      'username': 'root',
      // 金鑰認證,但 auth 裡保留著舊密碼(切回密碼認證時要還在)
      'auth': {'method': 'key', 'keyId': 'k-1', 'password': 'keep-me'},
      'pinned': true,
    });
    await pumpVaults(tester);

    // 開編輯、改名、存檔
    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('host-name')), 'srv2');
    await tester.tap(find.byKey(const Key('btn-save-host')));
    await tester.pumpAndSettle();

    final saved = service.byId(id)!;
    expect(saved.name, 'srv2');
    expect(saved.data['pinned'], isTrue, reason: '編輯不能弄丟置頂');
    final auth = (saved.data['auth'] as Map).cast<String, dynamic>();
    expect(auth['method'], 'key');
    expect(auth['keyId'], 'k-1');
    expect(auth['password'], 'keep-me', reason: '沒在編的 auth 欄位要保留');
  });

  // ---- 記住的主機指紋(第一次連線時存的)----

  const rememberedFp = 'SHA256:C2e8ILs2vZ7SvQxsU2QSoLr5dsCxeRgdbkWmO+LITpE';
  String addHostWithFingerprint() => service.upsert(kind: 'host', name: 'srv', data: {
        'address': '10.0.0.9',
        'port': 22,
        'username': 'root',
        'auth': {'method': 'password', 'password': 'pw'},
        'pinned': true,
        'hostKeyFingerprint': rememberedFp,
      });

  Future<void> tapVisible(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.tap(find.byKey(key));
    await tester.pump();
  }

  testWidgets('編輯 Host:顯示記住的指紋,清除要按儲存才生效', (tester) async {
    final id = addHostWithFingerprint();
    await pumpVaults(tester);
    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.byKey(const Key('host-fingerprint'))).data,
      rememberedFp,
    );
    expect(find.textContaining('只有伺服器重灌或換了主機金鑰時才需要清除'), findsOneWidget);

    // 清除後按取消:不變
    await tapVisible(tester, const Key('btn-clear-fingerprint'));
    expect(find.textContaining('儲存後會清除'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.byId(id)!.data['hostKeyFingerprint'], rememberedFp);

    // 清除 → 復原 → 儲存:不變
    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();
    await tapVisible(tester, const Key('btn-clear-fingerprint'));
    await tapVisible(tester, const Key('btn-undo-clear-fingerprint'));
    await tester.tap(find.byKey(const Key('btn-save-host')));
    await tester.pumpAndSettle();
    expect(service.byId(id)!.data['hostKeyFingerprint'], rememberedFp);

    // 清除 → 儲存:指紋沒了,其他欄位都在
    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();
    await tapVisible(tester, const Key('btn-clear-fingerprint'));
    await tester.tap(find.byKey(const Key('btn-save-host')));
    await tester.pumpAndSettle();
    final saved = service.byId(id)!;
    expect(saved.data.containsKey('hostKeyFingerprint'), isFalse);
    expect(saved.data['pinned'], isTrue);
    expect(saved.data['auth']['password'], 'pw');

    // 再打開:「還沒記住」,沒有清除鈕
    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-fingerprint-none')), findsOneWidget);
    expect(find.byKey(const Key('btn-clear-fingerprint')), findsNothing);
  });

  testWidgets('編輯 Host:位址或 port 改了,儲存時一併清除指紋', (tester) async {
    final id = addHostWithFingerprint();
    await pumpVaults(tester);

    // 新增 Host 的對話框沒有指紋區
    await tester.tap(find.byKey(const Key('btn-add-host')));
    await tester.pumpAndSettle();
    expect(find.text('主機指紋'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('host-port')), '2222');
    await tester.pump();
    expect(find.textContaining('位址或 Port 改了'), findsOneWidget);
    expect(find.byKey(const Key('btn-clear-fingerprint')), findsNothing);
    // 改回原值就不清
    await tester.enterText(find.byKey(const Key('host-port')), '22');
    await tester.pump();
    expect(find.textContaining('位址或 Port 改了'), findsNothing);

    await tester.enterText(find.byKey(const Key('host-address')), '10.0.0.10');
    await tester.pump();
    expect(find.textContaining('位址或 Port 改了'), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn-save-host')));
    await tester.pumpAndSettle();
    final saved = service.byId(id)!;
    expect(saved.data['address'], '10.0.0.10');
    expect(saved.data.containsKey('hostKeyFingerprint'), isFalse);
  });

  testWidgets('Key 新增 + Host 引用金鑰', (tester) async {
    await pumpVaults(tester);

    // Keys 分頁新增金鑰
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-add-key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('key-name')), 'deploy-key');
    await tester.enterText(
      find.byKey(const Key('key-private')),
      '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----',
    );
    await tester.tap(find.byKey(const Key('btn-save-key')));
    await tester.pumpAndSettle();
    expect(find.text('deploy-key'), findsOneWidget);

    // 回 Hosts,新增使用金鑰認證的 host
    await tester.tap(find.text('Hosts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-add-host')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('host-name')), 'kh');
    await tester.enterText(find.byKey(const Key('host-address')), '1.2.3.4');
    await tester.tap(find.byKey(const Key('host-auth')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SSH 金鑰').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('deploy-key').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-save-host')));
    await tester.pumpAndSettle();

    final host = service.hosts.single;
    final key = service.sshKeys.single;
    expect(host.data['auth']['method'], 'key');
    expect(host.data['auth']['keyId'], key.id);
    expect(find.textContaining('金鑰:deploy-key'), findsOneWidget);
  });

  // 與 core/tterm-ssh/tests/pubkey.rs 同一把測試金鑰(未加密 ed25519)。
  const testPrivateKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQAAAJjx5SxT8eUs
UwAAAAtzc2gtZWQyNTUxOQAAACAePoPUeGy1BYPUnU85k7BxEAFnLE22roHAmqT6Kr4nFQ
AAAEC+aPxLIOpZaxHv96OGN9KaCoTDSRdmzLUOCfDDNmjm/x4+g9R4bLUFg9SdTzmTsHEQ
AWcsTbaugcCapPoqvicVAAAAD3R0ZXJtLXRlc3QtaG9zdAECAwQFBg==
-----END OPENSSH PRIVATE KEY-----''';
  const testPublicKey =
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4+g9R4bLUFg9SdTzmTsHEQAWcsTbaug'
      'cCapPoqvicV tterm-test-host';
  const testFingerprint = 'SHA256:C2e8ILs2vZ7SvQxsU2QSoLr5dsCxeRgdbkWmO+LITpE';

  // 公鑰在背景 isolate 算(真非同步),要 runAsync 才會前進;pump 不能在
  // runAsync 裡呼叫,所以兩者交替直到畫面出現結果。
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(finder, findsWidgets, reason: '等不到公鑰算完');
  }

  testWidgets('Key 列表:算出公鑰指紋、一鍵複製公鑰', (tester) async {
    final id = service.upsert(
      kind: 'ssh_key',
      name: 'ed25519',
      data: {'privateKey': testPrivateKey},
    );
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpVaults(tester);
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();

    await waitFor(tester, find.textContaining(testFingerprint));
    expect(find.textContaining('ssh-ed25519'), findsWidgets, reason: '要顯示演算法');

    await tester.tap(find.byKey(ValueKey('btn-copy-pubkey-$id')));
    await tester.pump();
    expect(copied.single, testPublicKey);
  });

  testWidgets('編輯 Key:貼上私鑰就顯示公鑰,可從對話框複製', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpVaults(tester);
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-add-key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('key-private')), testPrivateKey);
    await tester.pump();

    await waitFor(tester, find.byKey(const Key('key-public')));
    expect(
      tester.widget<SelectableText>(find.byKey(const Key('key-public'))).data,
      testPublicKey,
    );

    await tester.tap(find.byKey(const Key('btn-copy-pubkey')));
    await tester.pump();
    expect(copied.single, testPublicKey);
  });

  // ---- 產生金鑰(手機上沒有 ssh-keygen)----

  testWidgets('產生金鑰:ed25519 + passphrase → 存成 ssh_key,直接複製公鑰', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpVaults(tester);
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();
    expect(find.textContaining('按「產生金鑰」建立新的'), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn-generate-key')));
    await tester.pumpAndSettle();
    final nameField = find.byKey(const Key('keygen-name'));
    expect(tester.widget<TextField>(nameField).controller!.text, 'tterminal-ed25519');
    await tester.enterText(nameField, 'phone');
    // 有 passphrase 才出現「再輸入一次」
    expect(find.byKey(const Key('keygen-passphrase-repeat')), findsNothing);
    await tester.enterText(find.byKey(const Key('keygen-passphrase')), 'pw');
    await tester.pump();
    await tester.enterText(find.byKey(const Key('keygen-passphrase-repeat')), 'pw');
    await tester.tap(find.byKey(const Key('btn-confirm-generate-key')));
    await tester.pump();
    await waitFor(tester, find.byKey(const Key('keygen-public')));

    final public =
        tester.widget<SelectableText>(find.byKey(const Key('keygen-public'))).data!;
    expect(public, startsWith('ssh-ed25519 AAAA'));
    expect(public, endsWith(' phone'), reason: 'comment 用名稱,authorized_keys 裡認得出來');

    // 跟貼上匯入同一種 record
    final key = service.sshKeys.single;
    expect(key.name, 'phone');
    final pem = key.data['privateKey'] as String;
    expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
    expect(key.data['passphrase'], 'pw');
    // 存下來的私鑰算得出同一把公鑰(連線、列表都走這條路)
    final derived = await tester.runAsync(
      () => SshPublicKeyInfo.derive(pem, passphrase: 'pw'),
    );
    expect(derived!.openssh, public);

    await tester.tap(find.byKey(const Key('btn-copy-generated-pubkey')));
    await tester.pump();
    expect(copied.single, public);

    await tester.tap(find.byKey(const Key('btn-keygen-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keygen-public')), findsNothing);
    expect(find.text('phone'), findsOneWidget);
    await waitFor(tester, find.textContaining(derived.fingerprint));
  });

  testWidgets('產生金鑰:名稱空白、passphrase 兩次不同 → 不產生', (tester) async {
    await pumpVaults(tester);
    await tester.tap(find.text('Keys'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn-generate-key')));
    await tester.pumpAndSettle();

    // 換成 RSA:名稱沒動過就跟著換預設
    await tester.tap(find.byKey(const Key('keygen-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RSA 4096(相容舊伺服器)').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('keygen-name'))).controller!.text,
      'tterminal-rsa',
    );

    await tester.enterText(find.byKey(const Key('keygen-passphrase')), 'a');
    await tester.pump();
    await tester.enterText(find.byKey(const Key('keygen-passphrase-repeat')), 'b');
    await tester.tap(find.byKey(const Key('btn-confirm-generate-key')));
    await tester.pump();
    expect(find.text('兩次輸入的 passphrase 不一樣'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('keygen-name')), '  ');
    await tester.tap(find.byKey(const Key('btn-confirm-generate-key')));
    await tester.pump();
    expect(find.text('名稱為必填'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.sshKeys, isEmpty);
  });

  testWidgets('設定頁:分頁位置切換 + 未設定同步的畫面', (tester) async {
    final prefs = AppPrefs.loadSync('${tmp.path}/prefs.json');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SettingsPage(service: service, prefs: prefs),
      ),
    );
    await tester.pump();

    expect(prefs.tabBarPosition, TabBarPosition.top);
    await tester.tap(find.byKey(const Key('radio-tabs-side')));
    await tester.pump();
    expect(prefs.tabBarPosition, TabBarPosition.side);

    // 終端機字體大小:+/- 調整、重設回預設
    expect(prefs.termFontSize, kTermFontDefaultSize);
    expect(find.text('${kTermFontDefaultSize.round()} pt'), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn-font-bigger')));
    await tester.pump();
    expect(prefs.termFontSize, kTermFontDefaultSize + 1);
    expect(find.text('${(kTermFontDefaultSize + 1).round()} pt'), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn-font-reset')));
    await tester.pump();
    expect(prefs.termFontSize, kTermFontDefaultSize);
    await tester.tap(find.byKey(const Key('btn-font-smaller')));
    await tester.pump();
    expect(prefs.termFontSize, kTermFontDefaultSize - 1);

    // 未設定同步:顯示建立/匯入按鈕
    expect(find.byKey(const Key('sync-server')), findsOneWidget);
    expect(find.byKey(const Key('btn-enable-sync')), findsOneWidget);
    expect(find.byKey(const Key('btn-import-pairing')), findsOneWidget);

    // 匯入 dialog 打開、貼壞字串 → 錯誤提示(SnackBar)且不設定同步
    await tester.tap(find.byKey(const Key('btn-import-pairing')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pairing-input')),
      'not-a-pairing-string',
    );
    await tester.tap(find.byKey(const Key('btn-confirm-import')));
    await tester.pumpAndSettle();
    expect(service.syncConfigured, isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
