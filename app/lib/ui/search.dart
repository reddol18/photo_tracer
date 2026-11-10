part of '../main.dart';

// ───────────────────────────── 검색: 처음 화면(인물·예시·최근 검색어) → 결과(이해한 내용 칩 + 순간 격자)

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const examples = ['바다에서 노는 아이', '생일 케이크', '눈 오는 날', '강아지 산책', '캠핑'];
  final ctrl = TextEditingController();
  final focus = FocusNode();
  List<Map<String, dynamic>>? items; // null이면 처음 화면
  String info = '';
  String? error;
  bool busy = false;
  // 인물 칩(#5): 검색어 속 인물 낱말마다 앱이 고른 인물. 눌러서 바꾸면 picks에 넣어 다시 검색한다
  List<Map<String, dynamic>> words = [];
  final picks = <String, List<int>>{};
  String rest = ''; // 인물 낱말을 뺀 나머지(장면)
  bool hint = false; // 칩을 한 번도 안 눌렀으면 "눌러서 바꿀 수 있어요"
  Map<int, Map<String, dynamic>> people = {}; // 등록한 인물: id → 이름·관계·대표 얼굴
  List<String> recent = [];

  @override
  void initState() {
    super.initState();
    loadPeople().then((p) {
      if (mounted) setState(() => people = {for (final e in p) e['id'] as int: e});
    }).catchError((_) {});
    pref('recent').then((r) {
      if (mounted && r != null && r.isNotEmpty) setState(() => recent = r.split('\n'));
    }).catchError((_) {});
  }

  Future<void> remember(String q) async {
    recent = [q, ...recent.where((e) => e != q)].take(8).toList();
    await setPref('recent', recent.isEmpty ? null : recent.join('\n'));
  }

  Future<void> forget(String? q) async {
    setState(() => recent = q == null ? [] : recent.where((e) => e != q).toList());
    await setPref('recent', recent.isEmpty ? null : recent.join('\n'));
  }

  Future<void> run(String q, {bool keepPicks = false}) async {
    q = q.trim();
    if (q.isEmpty) return;
    ctrl.text = q;
    focus.unfocus();
    if (!keepPicks) picks.clear();
    setState(() { busy = true; error = null; });
    remember(q);
    try {
      final r = Map<String, dynamic>.from(await channel.invokeMethod('search', {'q': q, 'picks': picks}));
      final list = (r['items'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
      final ws = ((r['words'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
      if (ws.isNotEmpty && people.isEmpty) people = {for (final e in await loadPeople()) e['id'] as int: e};
      setState(() {
        words = ws;
        hint = r['hint'] == true;
        rest = r['rest'] as String? ?? '';
        items = list;
        final photos = list.fold<int>(0, (a, e) => a + ((e['n'] as num?)?.toInt() ?? 1));
        info = r['who'] != null
            ? '${r['who']} 사진 ${fmtInt(r['photos'])}장 · ${rest.isEmpty ? '최근 순' : '"$rest" 잘 맞는 순'}'
            : '잘 맞는 순간 ${list.length}개 · 사진 ${fmtInt(photos)}장';
      });
    } catch (e) {
      setState(() { error = '검색하지 못했어요. 잠시 뒤 다시 해 주세요.'; items = []; });
    } finally {
      setState(() => busy = false);
    }
  }

  void clear() {
    ctrl.clear();
    setState(() { items = null; words = []; picks.clear(); });
  }

  List<int> ints(dynamic l) => (l as List).map((e) => (e as num).toInt()).toList();

  /// 인물 몇 명의 이름: "딸" / "딸 외 1명"
  String whoLabel(List<int> ids) {
    final names = ids.map((id) => people[id] != null ? personLabel(people[id]!) : '?').toList();
    return names.length <= 1 ? (names.isEmpty ? '?' : names.first) : '${names.first} 외 ${names.length - 1}명';
  }

  /// 인물 칩: 작은 얼굴 + 이름 + ▾. 테두리가 있는 칩 모양이라 누를 수 있는 것이 보이게(#5)
  Widget personChip(BuildContext context, Map<String, dynamic> w) {
    final cs = Theme.of(context).colorScheme;
    final chosen = ints(w['chosen']);
    return Material(
      color: Theme.of(context).cardTheme.color,
      shape: StadiumBorder(side: BorderSide(color: cs.primary, width: 1.5)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => choose(context, w),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            FaceAvatar(face: chosen.isEmpty ? null : people[chosen.first]?['face'] as int?, label: w['word'] as String, size: 26),
            const SizedBox(width: 6),
            // 검색어가 이름 그대로면 "딸(딸)"처럼 겹치지 않게 이름만, 관계 말(엄마 등)이면 "엄마: 이름"
            Text(whoLabel(chosen).startsWith(w['word'] as String) ? whoLabel(chosen) : '${w['word']}: ${whoLabel(chosen)}'),
            Icon(Icons.expand_more, size: 18, color: cs.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }

  /// 칩을 누르면: 그 낱말로 볼 수 있는 사람(풀이와 함께) 먼저, 그다음 다른 등록 인물. 고르면 바로 다시 검색
  Future<void> choose(BuildContext context, Map<String, dynamic> w) async {
    if (hint) { channel.invokeMethod('searchHintSeen'); setState(() => hint = false); }
    final word = w['word'] as String;
    final chosen = ints(w['chosen']);
    final cands = (w['cands'] as List).map((c) => (ids: ints(c['ids']), note: c['note'] as String)).toList();
    final covered = {for (final c in cands) if (c.ids.length == 1) c.ids.first};
    final others = people.keys.where((id) => !covered.contains(id)).toList();
    bool same(List<int> a) => a.length == chosen.length && a.toSet().containsAll(chosen);
    Widget tile(List<int> ids, String? note) => ListTile(
          leading: FaceAvatar(face: ids.isEmpty ? null : people[ids.first]?['face'] as int?, size: 40),
          title: Text(whoLabel(ids)),
          subtitle: note == null ? null : Text(note),
          trailing: same(ids) ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () => Navigator.pop(context, ids),
        );
    final picked = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text('"$word"은(는) 누구인가요?', style: Theme.of(context).textTheme.titleMedium)),
            for (final c in cands) tile(c.ids, c.note),
            if (others.isNotEmpty) const ListTile(dense: true, title: Text('다른 인물')),
            for (final id in others) tile([id], null),
          ]),
        ),
      ),
    );
    if (picked == null || same(picked)) return;
    picks[word] = picked;
    run(ctrl.text, keepPicks: true);
  }

  Widget chip(String text, VoidCallback onTap) => ActionChip(
        label: Text(text),
        onPressed: onTap,
        backgroundColor: Theme.of(context).cardTheme.color,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      );

  /// 처음 화면: 인물로 찾기 · 이렇게 찾아보세요 · 최근 검색
  Widget start(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ps = people.values.toList()..sort((a, b) => (b['n'] as int).compareTo(a['n'] as int));
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      if (ps.isNotEmpty) ...[
        const SectionLabel('인물로 찾기'),
        SizedBox(
          height: 92,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final p in ps)
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => run(p['name'] as String),
                  child: SizedBox(
                    width: 60,
                    child: Column(children: [
                      FaceAvatar(face: p['face'] as int?, label: p['name'] as String, size: 56),
                      const SizedBox(height: 6),
                      Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),
      ],
      const SectionLabel('이렇게 찾아보세요'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in [
          if (ps.isNotEmpty) '${withWa(ps.first['name'] as String)} 바다',
          ...examples,
        ])
          chip(e, () => run(e)),
      ]),
      const SizedBox(height: 12),
      Text('누가, 어디서, 무엇을 했는지 편하게 적어 보세요. "엄마의 딸"처럼 가족 관계로도 찾을 수 있어요.',
          style: TextStyle(fontSize: 13, height: 1.5, color: cs.onSurfaceVariant)),
      if (recent.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionLabel('최근 검색', trailing: TextButton(onPressed: () => forget(null), child: const Text('모두 지우기'))),
        for (final r in recent)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 4),
            leading: Icon(Icons.history, color: cs.onSurfaceVariant),
            title: Text(r),
            onTap: () => run(r),
            trailing: IconButton(tooltip: '이 검색어 지우기', icon: const Icon(Icons.close, size: 18), onPressed: () => forget(r)),
          ),
      ],
    ]);
  }

  Widget results(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = items!;
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (words.isNotEmpty) ...[
              Text(hint ? '이렇게 이해했어요 · 눌러서 바꿀 수 있어요' : '이렇게 이해했어요', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final w in words) personChip(context, w),
                if (rest.isNotEmpty)
                  Chip(label: Text('장면: $rest'), backgroundColor: cs.surfaceContainerHighest, side: BorderSide.none),
              ]),
              const SizedBox(height: 12),
            ],
            Text(error ?? (list.isEmpty ? '맞는 사진을 찾지 못했어요. 다른 말로 찾아보세요.' : info),
                style: TextStyle(fontSize: 13, color: error != null ? cs.error : cs.onSurfaceVariant)),
          ]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 14, crossAxisSpacing: 12, childAspectRatio: 0.82),
          delegate: SliverChildBuilderDelegate(childCount: list.length, (context, i) {
            final it = list[i];
            final label = it['date'] != null
                ? fmtDay(it['date'] as int, year: true)
                : it['received'] != null ? '받은 날 ${fmtDay(it['received'] as int, year: true)}' : '날짜 모름';
            final segment = it['kind'] == 'segment';
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                if (segment) {
                  final ids = it['ids']; // 인물 검색: 구간 안의 그 인물 사진만
                  Navigator.push(context, MaterialPageRoute(
                      builder: (_) => PhotosPage(title: label, load: () async => ids ?? await channel.invokeMethod('segmentPhotos', {'id': it['id']}))));
                } else {
                  showPhoto(context, it['cover'] as int);
                }
              },
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(14), child: SizedBox(width: double.infinity, child: Thumb(it['cover'] as int, size: 384)))),
                const SizedBox(height: 6),
                Text('$label${it['date_source'] == '이름' ? ' 무렵' : ''}', style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(segment ? '사진 ${it['n']}장' : '사진 1장', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ]),
            );
          }),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (items == null) const PageTitle('검색'),
      Padding(
        padding: EdgeInsets.fromLTRB(items == null ? 16 : 4, items == null ? 0 : 12, 16, 8),
        child: Row(children: [
          if (items != null) IconButton(tooltip: '뒤로', icon: const Icon(Icons.arrow_back), onPressed: clear),
          Expanded(
            child: TextField(
              controller: ctrl,
              focusNode: focus,
              textInputAction: TextInputAction.search,
              onSubmitted: run,
              decoration: InputDecoration(
                hintText: '누구와, 어디서, 무엇을',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).cardTheme.color,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: cs.outlineVariant)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: cs.outlineVariant)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: cs.primary, width: 1.5)),
                suffixIcon: busy
                    ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                    : ctrl.text.isEmpty ? null : IconButton(tooltip: '지우기', icon: const Icon(Icons.close), onPressed: clear),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ]),
      ),
      Expanded(child: items == null ? start(context) : results(context)),
    ]);
  }
}
