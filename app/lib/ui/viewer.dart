part of '../main.dart';

// ───────────────────────────── 사진 크게 보기 (넘겨 보기 · 공유 · 갤러리에서 열기 · 인물 고치기)

/// 사진 크게 보기. ids를 주면 옆으로 넘겨 본다. who를 주면 그 인물 얼굴을 굵게 보인다
Future<void> showPhoto(BuildContext context, int id, {int? who, List<int>? ids}) {
  final list = ids ?? [id];
  return Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewer(ids: list, start: list.indexOf(id).clamp(0, list.length - 1), who: who)));
}

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.ids, this.start = 0, this.who});
  final List<int> ids;
  final int start;
  final int? who;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final pages = PageController(initialPage: widget.start);
  late int index = widget.start;
  bool showFaces = true;
  final infos = <int, Map<String, dynamic>>{};
  List<Map<String, dynamic>> people = [];

  int get id => widget.ids[index];
  Map<String, dynamic>? get info => infos[id];

  @override
  void initState() {
    super.initState();
    loadPeople().then((p) => mounted ? setState(() => people = p) : null);
    load(id);
  }

  Future<void> load(int id) async {
    final m = Map<String, dynamic>.from(await channel.invokeMethod('photoInfo', {'id': id}) as Map);
    if (mounted) setState(() => infos[id] = m);
  }

  int? get year => info?['taken'] == null ? null : DateTime.fromMillisecondsSinceEpoch(info!['taken'] as int).year;

  /// 얼굴 상자 위 이름표: 이름 + 그때 나이(생년과 찍은 해로)
  Map<int, String> labelsFor(int? year) => {
        for (final e in people)
          e['id'] as int: switch ((year, e['birth_year'] as int?)) {
            (final y?, final b?) when y >= b => '${e['name']} ${y - b}살',
            _ => e['name'] as String,
          }
      };

  List<Map<String, dynamic>> facesOf(int id) =>
      infos[id] == null ? [] : (infos[id]!['faces'] as List).map((e) => Map<String, dynamic>.from(e)).toList();

  Future<void> act(String method) async {
    final ok = await channel.invokeMethod<bool>(method, {'id': id});
    if (ok != true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(method == 'share' ? '공유할 앱을 찾지 못했어요' : '사진을 열 앱을 찾지 못했어요')));
    }
  }

  void details() {
    final m = info;
    if (m == null) return;
    final src = m['date_source'];
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('사진 정보', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(m['taken'] == null ? '찍은 날을 몰라요' : '찍은 날 ${fmtDay(m['taken'] as int, year: true)} ${fmtTime(m['taken'] as int)}'),
            if (src == '이름') Text('파일 이름에서 날짜를 짐작했어요', style: Theme.of(context).textTheme.bodySmall),
            if (m['received'] != null) Text('받은 날 ${fmtDay(m['received'] as int, year: true)}'),
            const SizedBox(height: 8),
            Text('얼굴 ${(m['faces'] as List).length}개', style: Theme.of(context).textTheme.bodySmall),
            // 앱이 짐작해 붙인 이름(직접 고른 것 아님)이 모두 틀렸을 때 한 번에 빼기
            if (facesOf(id).any((f) => (f['who'] ?? f['maybe']) != null && f['sim'] != 1.0))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.person_off_outlined),
                  label: const Text('앱이 붙인 이름이 모두 틀렸어요'),
                  onPressed: () async {
                    Navigator.pop(context);
                    await channel.invokeMethod('whoRejectAll', {'photo': id});
                    load(id);
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// 얼굴을 누르면: 이 사람 아니에요 / 누구인지 고르기(새 인물 포함)
  Future<void> onFace(Map<String, dynamic> f) async {
    final faceId = f['id'] as int;
    final cur = (f['who'] ?? f['maybe']) as int?;
    final names = {for (final e in people) e['id'] as int: personLabel(e)};
    final no = {?cur, ?widget.who}.where(names.containsKey).toList();
    final list = [...people.where((e) => e['id'] == cur), ...people.where((e) => e['id'] != cur)];
    final y = year;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        final t = Theme.of(context).textTheme;
        Widget card({required Widget face, required String name, String? sub, bool on = false, required String value}) => InkWell(
              onTap: () => Navigator.pop(context, value),
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 88,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(children: [
                    Container(
                      width: 64, height: 64,
                      decoration: on ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3)) : null,
                      child: ClipOval(child: face),
                    ),
                    const SizedBox(height: 6),
                    Text(name, style: t.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(sub ?? '', style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('이 얼굴은 누구인가요?', style: t.titleMedium),
              const SizedBox(height: 4),
              Text('골라 주시면 닮은 얼굴을 더 잘 찾아요', style: t.bodySmall),
              const SizedBox(height: 12),
              SizedBox(
                height: 124,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  card(face: Container(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const Icon(Icons.person_add_alt, size: 28)),
                      name: '새 인물', value: 'new'),
                  for (final p in list)
                    card(
                      face: FaceAvatar(face: p['face'] as int?, label: p['name'] as String, size: 64),
                      name: p['name'] as String,
                      sub: switch ((y, p['birth_year'] as int?)) {
                        (final y?, final b?) when y >= b => '그때 ${y - b}살',
                        _ => p['relation'] as String?,
                      },
                      on: p['id'] == cur,
                      value: 'ok:${p['id']}',
                    ),
                ]),
              ),
              for (final p in no)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_off_outlined),
                  title: Text('"${names[p]}" 아니에요'),
                  onTap: () => Navigator.pop(context, 'no:$p'),
                ),
            ]),
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    if (choice == 'new') {
      final n = await askPerson(context, '새 인물');
      if (n == null) return;
      await channel.invokeMethod('whoCreate', {...n, 'faces': [faceId]});
      people = await loadPeople();
    } else {
      final [op, person] = choice.split(':');
      await channel.invokeMethod('whoMark', {'id': int.parse(person), 'faces': [faceId], 'ok': op == 'ok'});
    }
    load(id);
  }

  @override
  Widget build(BuildContext context) {
    final m = info;
    final faces = facesOf(id);
    final named = faces.where((f) => (f['who'] ?? f['maybe']) != null).toList();
    final names = {for (final e in people) e['id'] as int: e['name'] as String};
    final who = [for (final f in named) names[(f['who'] ?? f['maybe']) as int]].nonNulls.toSet().join(', ');
    const fg = Color(0xFFF9FAFB);
    Widget action(IconData icon, String label, VoidCallback? onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 72,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: fg, size: 22),
                const SizedBox(height: 6),
                Text(label, style: const TextStyle(color: fg, fontSize: 12)),
              ]),
            ),
          ),
        );
    return Theme(
      data: buildTheme(Look.current.value.accent, Brightness.dark),
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0B0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0B0B0D),
          foregroundColor: fg,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m == null ? '' : m['taken'] == null ? '찍은 날 모름' : fmtDay(m['taken'] as int, year: true),
                style: const TextStyle(fontSize: 16, color: fg)),
            Text('${m?['taken'] == null ? '' : '${fmtTime(m!['taken'] as int)} · '}${index + 1} / ${widget.ids.length}',
                style: const TextStyle(fontSize: 12, color: Color(0xFFD1D5DB))),
          ]),
        ),
        body: Column(children: [
          Expanded(
            child: PageView.builder(
              controller: pages,
              itemCount: widget.ids.length,
              onPageChanged: (i) {
                setState(() => index = i);
                if (!infos.containsKey(widget.ids[i])) load(widget.ids[i]);
              },
              itemBuilder: (context, i) {
                final pid = widget.ids[i];
                final y = infos[pid]?['taken'] == null ? null : DateTime.fromMillisecondsSinceEpoch(infos[pid]!['taken'] as int).year;
                return Center(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: FacePhoto(pid, key: ValueKey('$pid/${infos[pid]?.hashCode}'), faces: facesOf(pid), names: labelsFor(y),
                        who: widget.who, onFace: onFace, showBoxes: showFaces),
                  ),
                );
              },
            ),
          ),
          if (faces.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(children: [
                Expanded(
                  child: Text(who.isEmpty ? '얼굴 ${faces.length}개 · 얼굴을 눌러 누구인지 알려 주세요' : '$who · 얼굴을 눌러 고칠 수 있어요',
                      style: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 13)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36), foregroundColor: fg, side: const BorderSide(color: Color(0xFF4B5563))),
                  onPressed: () => setState(() => showFaces = !showFaces),
                  child: Text(showFaces ? '얼굴 숨기기' : '얼굴 보기', style: const TextStyle(fontSize: 13)),
                ),
              ]),
            ),
          const Divider(height: 1, color: Color(0xFF1F2937)),
          SafeArea(
            top: false,
            child: Row(children: [
              action(Icons.share_outlined, '공유', () => act('share')),
              action(Icons.open_in_new, '갤러리에서 열기', () => act('openInGallery')),
              action(Icons.info_outline, '정보', details),
            ]),
          ),
        ]),
      ),
    );
  }
}
