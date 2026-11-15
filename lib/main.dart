import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'td.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    title: 'TG Finder',
    theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
    home: const Root(),
  ));
}

void toast(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  bool loading = true, hasCreds = false;
  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getInt('api_id'), h = p.getString('api_hash');
    if (id != null && h != null) {
      await Td.i.start(id, h);
      hasCreds = true;
    }
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext c) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!hasCreds) return Creds(onDone: init);
    return ValueListenableBuilder<String>(
      valueListenable: Td.i.auth,
      builder: (_, s, __) {
        switch (s) {
          case 'authorizationStateWaitPhoneNumber':
            return Ask('Tu número de Telegram', '+34123456789', TextInputType.phone, Td.i.phone);
          case 'authorizationStateWaitCode':
            return Ask('Código que te llegó a Telegram', '12345', TextInputType.number, Td.i.code);
          case 'authorizationStateWaitPassword':
            return Ask('Contraseña de verificación en dos pasos', '', TextInputType.text, Td.i.password, secret: true);
          case 'authorizationStateReady':
            return const SearchPage();
          default:
            return Scaffold(body: Center(child: Text(s == 'init' ? 'Iniciando…' : s)));
        }
      },
    );
  }
}

class Creds extends StatelessWidget {
  final Future<void> Function() onDone;
  Creds({super.key, required this.onDone});
  final a = TextEditingController(), b = TextEditingController();
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Configuración inicial')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            const Text('Obtén api_id y api_hash gratis en my.telegram.org → API development tools.'),
            const SizedBox(height: 12),
            TextField(controller: a, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'api_id', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: b, decoration: const InputDecoration(labelText: 'api_hash', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                final id = int.tryParse(a.text.trim());
                if (id == null || b.text.trim().isEmpty) return toast(c, 'Datos inválidos');
                final p = await SharedPreferences.getInstance();
                await p.setInt('api_id', id);
                await p.setString('api_hash', b.text.trim());
                await onDone();
              },
              child: const Text('Guardar y continuar'),
            ),
          ]),
        ),
      );
}

class Ask extends StatefulWidget {
  final String label, hint;
  final TextInputType type;
  final Future<void> Function(String) action;
  final bool secret;
  const Ask(this.label, this.hint, this.type, this.action, {super.key, this.secret = false});
  @override
  State<Ask> createState() => _AskState();
}

class _AskState extends State<Ask> {
  final t = TextEditingController();
  bool busy = false;
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Iniciar sesión')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(controller: t, keyboardType: widget.type, obscureText: widget.secret,
                decoration: InputDecoration(labelText: widget.label, hintText: widget.hint, border: const OutlineInputBorder())),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : () async {
                setState(() => busy = true);
                try {
                  await widget.action(t.text.trim());
                } catch (e) {
                  if (c.mounted) toast(c, '$e');
                }
                if (mounted) setState(() => busy = false);
              },
              child: Text(busy ? 'Enviando…' : 'Continuar'),
            ),
          ]),
        ),
      );
}

class Res {
  final String title, sub;
  final IconData icon;
  final Future<String?> Function() link;
  Res(this.title, this.sub, this.icon, this.link);
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final ctl = TextEditingController();
  final res = <String, Res>{};
  final titles = <int, String>{};
  bool files = false, busy = false;
  String status = '';
  final td = Td.i;

  Future<Map?> safe(Map<String, dynamic> q) async {
    try {
      return await td.call(q);
    } catch (_) {
      return null;
    }
  }

  Future<String> chatTitle(int id) async {
    if (titles.containsKey(id)) return titles[id]!;
    final r = await safe({'@type': 'getChat', 'chat_id': id});
    return titles[id] = '${r?['title'] ?? id}';
  }

  String size(num? b) {
    if (b == null || b == 0) return '';
    if (b > 1e9) return '${(b / 1e9).toStringAsFixed(1)} GB';
    if (b > 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB';
    return '${(b / 1e3).toStringAsFixed(0)} KB';
  }

  Future<List<Map>> channels(String k, [String? must]) async {
    final ids = <int>{};
    for (final q in <Map<String, dynamic>>[
      {'@type': 'searchPublicChats', 'query': k},
      {'@type': 'searchChatsOnServer', 'query': k, 'limit': 50},
      {'@type': 'searchChats', 'query': k, 'limit': 50},
    ]) {
      final r = await safe(q);
      if (r != null) ids.addAll((r['chat_ids'] as List).cast<int>());
    }
    final out = <Map>[];
    var n = 0;
    for (final id in ids) {
      setState(() => status = 'Analizando canales ${++n}/${ids.length}…');
      final ch = await safe({'@type': 'getChat', 'chat_id': id});
      final ty = ch?['type'] as Map?;
      if (ty == null || ty['@type'] != 'chatTypeSupergroup') continue;
      final sg = await safe({'@type': 'getSupergroup', 'supergroup_id': ty['supergroup_id']});
      final un = ((sg?['usernames'] as Map?)?['active_usernames'] as List?)?.firstOrNull ?? '';
      if (must != null && !'${ch!['title']} $un'.toLowerCase().contains(must)) continue;
      final isCh = ty['is_channel'] == true;
      titles[id] = '${ch!['title']}';
      final item = {'id': id, 'title': ch['title'], 'user': un, 'channel': isCh};
      out.add(item);
      if (!files) {
        res['c$id'] = Res('${ch['title']}',
            '${un.isNotEmpty ? '@$un · ' : ''}${isCh ? 'Canal' : 'Grupo'} · ${sg?['member_count'] ?? '?'} miembros',
            isCh ? Icons.campaign : Icons.groups,
            () async => un.isNotEmpty ? 'tg://resolve?domain=$un' : null);
        setState(() {});
      }
    }
    return out;
  }

  Future<void> addMessages(List? msgs, [String? must]) async {
    for (final m in (msgs ?? [])) {
      final ct = m['content'] as Map;
      Map? f;
      String name = '';
      IconData ic = Icons.insert_drive_file;
      switch (ct['@type']) {
        case 'messageDocument':
          f = ct['document'];
          name = f?['file_name'] ?? '';
          break;
        case 'messageVideo':
          f = ct['video'];
          name = f?['file_name'] ?? '';
          ic = Icons.movie;
          break;
        case 'messageAudio':
          f = ct['audio'];
          name = f?['file_name'] ?? f?['title'] ?? '';
          ic = Icons.audiotrack;
          break;
        case 'messageText':
          name = ((ct['text'] as Map?)?['text'] ?? '').toString().split('\n').first;
          ic = Icons.chat_bubble_outline;
          break;
        default:
          continue;
      }
      final cap = (ct['caption'] as Map?)?['text'] ?? (ct['text'] as Map?)?['text'] ?? '';
      if (must != null && !'$name $cap'.toLowerCase().contains(must)) continue;
      final cid = m['chat_id'] as int, mid = m['id'] as int;
      final sz = size((f?[ct['@type'] == 'messageDocument' ? 'document' : ct['@type'] == 'messageVideo' ? 'video' : 'audio'] as Map?)?['size']);
      res['$cid:$mid'] = Res(name.isNotEmpty ? name : '$cap'.split('\n').first,
          '${await chatTitle(cid)}${sz.isNotEmpty ? ' · $sz' : ''}', ic, () async {
        final r = await safe({'@type': 'getMessageLink', 'chat_id': cid, 'message_id': mid, 'for_album': false, 'for_comment': false});
        return r?['link'] as String?;
      });
    }
    setState(() {});
  }

  Future<void> search() async {
    var raw = ctl.text.trim();
    String? target, must;
    final m = RegExp(r'^(?:https?://)?(?:t\.me/|@)([A-Za-z0-9_]{4,})\s*(.*)$').firstMatch(raw);
    if (m != null) {
      target = m.group(1);
      raw = m.group(2)!.trim();
    }
    if (raw.length > 2 && raw.startsWith('"') && raw.endsWith('"')) {
      raw = raw.substring(1, raw.length - 1).trim();
      must = raw.toLowerCase();
    }
    if (raw.isEmpty && target == null) return;
    final k = raw;
    const filters = ['searchMessagesFilterDocument', 'searchMessagesFilterVideo', 'searchMessagesFilterAudio'];
    setState(() {
      res.clear();
      busy = true;
      status = target != null ? 'Abriendo @$target…' : 'Buscando canales…';
    });
    if (target != null) {
      final chat = await safe({'@type': 'searchPublicChat', 'username': target});
      if (chat == null) {
        setState(() {
          busy = false;
          status = 'Canal @$target no encontrado';
        });
        return;
      }
      final id = chat['id'] as int;
      titles[id] = '${chat['title']}';
      for (final f in (files ? filters : ['searchMessagesFilterEmpty'])) {
        var from = 0;
        for (var pg = 1; pg <= 10; pg++) {
          setState(() => status = '@$target: página $pg (${res.length} resultados)…');
          final r = await safe({'@type': 'searchChatMessages', 'chat_id': id, 'query': k, 'from_message_id': from, 'offset': 0, 'limit': 100, 'filter': {'@type': f}});
          final msgs = (r?['messages'] as List?) ?? [];
          if (msgs.isEmpty) break;
          await addMessages(msgs, must);
          from = msgs.last['id'] as int;
        }
      }
      setState(() {
        busy = false;
        status = '${res.length} resultados en @$target';
      });
      return;
    }
    final chs = await channels(k, must);
    if (files) {
      for (final f in filters) {
        setState(() => status = 'Búsqueda global de archivos…');
        final r = await safe({'@type': 'searchMessages', 'query': k, 'offset': '', 'limit': 100, 'filter': {'@type': f}, 'min_date': 0, 'max_date': 0});
        await addMessages(r?['messages'] as List?, must);
      }
      var n = 0;
      final pub = chs.where((e) => '${e['user']}'.isNotEmpty).take(25).toList();
      for (final ch in pub) {
        setState(() => status = 'Buscando dentro de canales ${++n}/${pub.length}…');
        for (final f in filters) {
          final r = await safe({'@type': 'searchChatMessages', 'chat_id': ch['id'], 'query': k, 'from_message_id': 0, 'offset': 0, 'limit': 50, 'filter': {'@type': f}});
          await addMessages(r?['messages'] as List?, must);
        }
      }
    }
    setState(() {
      busy = false;
      status = '${res.length} resultados';
    });
  }

  @override
  Widget build(BuildContext c) {
    final list = res.values.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('TG Finder')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: ctl,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => busy ? null : search(),
            decoration: InputDecoration(
              hintText: 'palabra, "frase exacta" o @canal palabra',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: busy ? null : search),
            ),
          ),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Canales'), icon: Icon(Icons.campaign)),
            ButtonSegment(value: true, label: Text('Archivos'), icon: Icon(Icons.attach_file)),
          ],
          selected: {files},
          onSelectionChanged: (s) => setState(() => files = s.first),
        ),
        if (busy) const LinearProgressIndicator(),
        Padding(padding: const EdgeInsets.all(6), child: Text(status)),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final h = list[i];
              return ListTile(
                leading: Icon(h.icon),
                title: Text(h.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(h.sub, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () async {
                  final l = await h.link();
                  if (l == null) return toast(c, 'Sin enlace público');
                  await launchUrl(Uri.parse(l), mode: LaunchMode.externalApplication);
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
