import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

typedef _SendC = Void Function(Int32, Pointer<Utf8>);
typedef _SendD = void Function(int, Pointer<Utf8>);
typedef _ExecC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CreateC = Int32 Function();
typedef _CreateD = int Function();
typedef _RecvC = Pointer<Utf8> Function(Double);
typedef _RecvD = Pointer<Utf8> Function(double);

void _rx(SendPort p) {
  final lib = DynamicLibrary.open('libtdjson.so');
  final recv = lib.lookupFunction<_RecvC, _RecvD>('td_receive');
  while (true) {
    final r = recv(1.0);
    if (r.address != 0) p.send(r.toDartString());
  }
}

class TdError implements Exception {
  final int code;
  final String message;
  TdError(this.code, this.message);
  @override
  String toString() => message;
}

class Td {
  Td._();
  static final i = Td._();
  late int _cid;
  late _SendD _send;
  final _pending = <String, Completer<Map>>{};
  int _n = 0;
  final auth = ValueNotifier<String>('init');
  late int apiId;
  late String apiHash;
  bool started = false;

  Future<void> start(int id, String hash) async {
    if (started) return;
    started = true;
    apiId = id;
    apiHash = hash;
    final lib = DynamicLibrary.open('libtdjson.so');
    _send = lib.lookupFunction<_SendC, _SendD>('td_send');
    try {
      final ex = lib.lookupFunction<_ExecC, _ExecC>('td_execute');
      final s = '{"@type":"setLogVerbosityLevel","new_verbosity_level":1}'.toNativeUtf8();
      ex(s);
      malloc.free(s);
    } catch (_) {}
    _cid = lib.lookupFunction<_CreateC, _CreateD>('td_create_client_id')();
    final port = ReceivePort();
    port.listen((m) => _handle(m as String));
    await Isolate.spawn(_rx, port.sendPort);
    _raw({'@type': 'getOption', 'name': 'version'});
  }

  void _raw(Map q) {
    final s = jsonEncode(q).toNativeUtf8();
    _send(_cid, s);
    malloc.free(s);
  }

  Future<Map> call(Map<String, dynamic> q, {bool retry = true}) async {
    final extra = '${++_n}';
    final c = Completer<Map>();
    _pending[extra] = c;
    _raw({...q, '@extra': extra});
    try {
      return await c.future.timeout(const Duration(seconds: 40));
    } on TdError catch (e) {
      if (e.code == 429 && retry) {
        final m = RegExp(r'(\d+)').firstMatch(e.message);
        await Future.delayed(Duration(seconds: int.tryParse(m?.group(1) ?? '5') ?? 5));
        return call(q, retry: false);
      }
      rethrow;
    } finally {
      _pending.remove(extra);
    }
  }

  void _handle(String s) {
    final j = jsonDecode(s) as Map;
    final extra = j['@extra'];
    if (extra != null && _pending.containsKey(extra)) {
      final c = _pending[extra]!;
      if (j['@type'] == 'error') {
        c.completeError(TdError(j['code'] ?? 0, '${j['message']}'));
      } else {
        c.complete(j);
      }
    } else if (j['@type'] == 'updateAuthorizationState') {
      _onAuth(j['authorization_state'] as Map);
    }
  }

  Future<void> _onAuth(Map st) async {
    final t = st['@type'] as String;
    if (t == 'authorizationStateWaitTdlibParameters') {
      final d = await getApplicationSupportDirectory();
      _raw({
        '@type': 'setTdlibParameters',
        'use_test_dc': false,
        'database_directory': '${d.path}/td',
        'files_directory': '${d.path}/tdfiles',
        'use_file_database': true,
        'use_chat_info_database': true,
        'use_message_database': true,
        'use_secret_chats': false,
        'api_id': apiId,
        'api_hash': apiHash,
        'system_language_code': 'es',
        'device_model': 'Android',
        'system_version': '13',
        'application_version': '2.0',
      });
    }
    auth.value = t;
  }

  Future<void> phone(String p) => call({'@type': 'setAuthenticationPhoneNumber', 'phone_number': p});
  Future<void> code(String c) => call({'@type': 'checkAuthenticationCode', 'code': c});
  Future<void> password(String p) => call({'@type': 'checkAuthenticationPassword', 'password': p});
}
