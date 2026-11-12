part of '../main.dart';

// ───────────────────────────── 검색: 처음 화면(인물·예시·최근 검색어) → 결과(이해한 내용 칩 + 순간 격자)

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  /// 개발용 확인 통로 — 출시 전 정리 대상: Shell이 adb 검색어를 여기 넣으면 사람이 입력한 것처럼 run()으로 검색한다(디버그만)
  static final debugQuery = ValueNotifier<String?>(null);

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
  String query = ''; // 마지막으로 검색한 말. 인물 더하기·빼기(#14·#15)는 이 글자를 고쳐 다시 검색한다(따로 상태 없음)
  // 시기 칩(#16): Kotlin이 읽은 시기 말. words(검색어에서 뺄 낱말), text, range, who, need(owner|birth), cands
  Map<String, dynamic>? period;
  static const agePick = '@나이'; // picks에서 '누구 나이인지' 고른 인물의 열쇠(인물 낱말과 겹치지 않는 말)
  // Kotlin Search와 같은 조사·군말: "딸이랑"의 낱말은 "딸", "사진"만 남으면 검색할 말이 없는 것
  static const josa = ['이하고', '이랑', '이와', '이가', '이는', '이를', '이의', '이도', '이만', '에게', '한테', '하고',
      '랑', '와', '과', '의', '은', '는', '이', '가', '을', '를', '도', '만'];
  static const filler = {'사진', '사진들', '같이', '함께', '나온', '있는', '찍은'};

  @override
  void initState() {
    super.initState();
    loadPeople().then((p) {
      if (mounted) setState(() => people = {for (final e in p) e['id'] as int: e});
    }).catchError((_) {});
    pref('recent').then((r) {
      if (mounted && r != null && r.isNotEmpty) setState(() => recent = r.split('\n'));
    }).catchError((_) {});
    if (kDebugMode) {
      SearchPage.debugQuery.addListener(onDebugQuery);
      onDebugQuery();
    }
  }

  @override
  void dispose() {
    SearchPage.debugQuery.removeListener(onDebugQuery);
    super.dispose();
  }

  /// 개발용 확인 통로 — 출시 전 정리 대상: 새 검색으로(고른 인물·나이 주인은 비운다). 검색 중이면 끝난 뒤 한다
  void onDebugQuery() {
    final q = SearchPage.debugQuery.value;
    if (!kDebugMode || q == null || !mounted) return;
    if (busy) {
      Future.delayed(const Duration(milliseconds: 300), onDebugQuery);
      return;
    }
    SearchPage.debugQuery.value = null;
    run(q);
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
    query = q;
    focus.unfocus();
    if (!keepPicks) picks.clear();
    setState(() { busy = true; error = null; });
    remember(q);
    try {
      final r = Map<String, dynamic>.from(await channel.invokeMethod('search', {'q': q, 'picks': picks}));
      final list = (r['items'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
      final ws = ((r['words'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
      final when = r['when'] == null ? null : Map<String, dynamic>.from(r['when'] as Map);
      if ((ws.isNotEmpty || when != null) && people.isEmpty) people = {for (final e in await loadPeople()) e['id'] as int: e};
      setState(() {
        words = ws;
        period = when;
        hint = r['hint'] == true;
        rest = r['rest'] as String? ?? '';
        items = list;
        final photos = list.fold<int>(0, (a, e) => a + ((e['n'] as num?)?.toInt() ?? 1));
        info = r['who'] != null
            ? '${r['who']} 사진 ${fmtInt(r['photos'])}장 · ${rest.isEmpty ? '최근 순' : '"$rest" 잘 맞는 순'}'
            : r['recent'] == true
                ? '순간 ${list.length}개 · 사진 ${fmtInt(photos)}장 · 최근 순'
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
    query = '';
    setState(() { items = null; words = []; period = null; picks.clear(); });
  }

  List<String> tokens(String q) => q.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

  /// 검색어 낱말 tok이 인물 낱말 word인지: 그대로이거나 조사가 붙은 것("딸", "딸이랑")
  bool isWord(String tok, String word) => tok == word || josa.any((j) => tok == '$word$j');

  /// 인물 빼기(#15): 검색어에서 그 낱말들을 지우고 다시 검색. 남은 말이 없으면 처음 화면
  void dropWords(Iterable<String> ws) {
    if (busy) return;
    final drop = ws.toSet();
    final left = tokens(query).where((t) => !drop.any((w) => isWord(t, w))).toList();
    for (final w in drop) {
      picks.remove(w);
    }
    if (left.every(filler.contains)) {
      clear();
    } else {
      run(left.join(' '), keepPicks: true);
    }
  }

  /// 인물 더하기(#14): 검색어 맨 앞 인물 낱말들 뒤에 이름을 넣어 다시 검색("딸 바다" + 아들 → "딸 아들 바다").
  /// 이름의 빈칸은 뺀다(Kotlin도 빈칸 없이 맞춘다). 이름이 이미 검색어에 있는데 다른 사람으로 풀렸으면 그 사람으로 고른다
  void addPerson(int id) {
    if (busy) return;
    final name = (people[id]!['name'] as String).replaceAll(' ', '');
    final toks = tokens(query);
    if (toks.any((t) => isWord(t, name))) {
      picks[name] = [id];
      run(query, keepPicks: true);
      return;
    }
    var i = 0;
    while (i < toks.length && words.any((w) => isWord(toks[i], w['word'] as String))) {
      i++;
    }
    toks.insert(i, name);
    run(toks.join(' '), keepPicks: true);
  }

  /// 결과 화면 얼굴 줄: 결과에 든 사람이면 빼고, 아니면 더한다
  void toggle(int id) {
    final hits = [for (final w in words) if (ints(w['chosen']).contains(id)) w['word'] as String];
    hits.isEmpty ? addPerson(id) : dropWords(hits);
  }

  List<int> ints(dynamic l) => (l as List).map((e) => (e as num).toInt()).toList();

  /// 시기 빼기(#16): 검색어에서 시기 말 낱말들을(처음 나온 것 하나씩) 지우고 다시 검색. 남은 말이 없으면 처음 화면
  void dropPeriod() {
    if (busy || period == null) return;
    final left = tokens(query);
    for (final w in (period!['words'] as List).cast<String>()) {
      left.remove(w);
    }
    picks.remove(agePick);
    if (left.every(filler.contains)) {
      clear();
    } else {
      run(left.join(' '), keepPicks: true);
    }
  }

  /// 시기 칩의 글: "작년: 2025년", "2025년", "딸 1살 때: 2019년", "1살 때: 누구 나이인가요?", "딸 1살 때: 생년을 넣어 주세요"
  String periodLabel(Map<String, dynamic> p) {
    final text = p['text'] as String;
    final who = p['who'] as String?;
    final head = who == null ? text : '$who $text';
    return switch (p['need']) {
      'owner' => '$text: 누구 나이인가요?',
      'birth' => '$head: 생년을 넣어 주세요',
      _ => p['range'] == text ? text : '$head: ${p['range']}',
    };
  }

  /// 시기 칩: 달력 아이콘 + 읽은 시기와 기간 + ✕. '누구 나이인가요?'면 눌러서 인물을 고른다
  Widget periodChip(BuildContext context, Map<String, dynamic> p) {
    final cs = Theme.of(context).colorScheme;
    final ask = p['need'] == 'owner';
    final warn = p['need'] != null;
    return Material(
      key: const ValueKey('period-chip'),
      color: Theme.of(context).cardTheme.color,
      shape: StadiumBorder(side: BorderSide(color: warn ? cs.error : cs.primary, width: 1.5)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: InkWell(
            onTap: ask ? () => chooseOwner(context, p) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 2, 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.event, size: 18, color: warn ? cs.error : cs.primary),
                const SizedBox(width: 6),
                Flexible(child: Text(periodLabel(p), maxLines: 2, overflow: TextOverflow.ellipsis)),
                if (ask) Icon(Icons.expand_more, size: 18, color: cs.onSurfaceVariant),
              ]),
            ),
          ),
        ),
        IconButton(
          tooltip: '${p['text']} 빼기',
          onPressed: dropPeriod,
          icon: const Icon(Icons.close),
          iconSize: 16,
          color: cs.onSurfaceVariant,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
      ]),
    );
  }

  /// 나이 말의 인물 고르기: 생년을 넣은 인물 중에서. 고르면 picks에 넣어 다시 검색(검색어는 그대로)
  Future<void> chooseOwner(BuildContext context, Map<String, dynamic> p) async {
    final ids = ints(p['cands'] ?? []);
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text('"${p['text']}"은(는) 누구 나이인가요?', style: Theme.of(context).textTheme.titleMedium)),
            for (final id in ids)
              ListTile(
                leading: FaceAvatar(face: people[id]?['face'] as int?, size: 40),
                title: Text(people[id] != null ? personLabel(people[id]!) : '?'),
                subtitle: people[id]?['birth_year'] != null ? Text('${people[id]!['birth_year']}년생') : null,
                onTap: () => Navigator.pop(context, id),
              ),
          ]),
        ),
      ),
    );
    if (picked == null) return;
    picks[agePick] = [picked];
    run(query, keepPicks: true);
  }

  /// 인물 몇 명의 이름: "딸" / "딸 외 1명"
  String whoLabel(List<int> ids) {
    final names = ids.map((id) => people[id] != null ? personLabel(people[id]!) : '?').toList();
    return names.length <= 1 ? (names.isEmpty ? '?' : names.first) : '${names.first} 외 ${names.length - 1}명';
  }

  /// 인물 칩: 작은 얼굴 + 이름 + ▾ + ✕. 테두리가 있는 칩 모양이라 누를 수 있는 것이 보이게(#5).
  /// 본체를 누르면 누구로 볼지 바꾸기, ✕는 이 낱말을 검색어에서 빼기(#15)
  Widget personChip(BuildContext context, Map<String, dynamic> w) {
    final cs = Theme.of(context).colorScheme;
    final chosen = ints(w['chosen']);
    final word = w['word'] as String;
    return Material(
      color: Theme.of(context).cardTheme.color,
      shape: StadiumBorder(side: BorderSide(color: cs.primary, width: 1.5)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: InkWell(
            onTap: () => choose(context, w),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 7, 2, 7),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                FaceAvatar(face: chosen.isEmpty ? null : people[chosen.first]?['face'] as int?, label: word, size: 26),
                const SizedBox(width: 6),
                // 검색어가 이름 그대로면 "딸(딸)"처럼 겹치지 않게 이름만, 관계 말(엄마 등)이면 "엄마: 이름"
                Flexible(
                  child: Text(whoLabel(chosen).startsWith(word) ? whoLabel(chosen) : '$word: ${whoLabel(chosen)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Icon(Icons.expand_more, size: 18, color: cs.onSurfaceVariant),
              ]),
            ),
          ),
        ),
        IconButton(
          tooltip: '$word 빼기',
          onPressed: () => dropWords([word]),
          icon: const Icon(Icons.close),
          iconSize: 16,
          color: cs.onSurfaceVariant,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
      ]),
    );
  }

  /// 결과 화면 맨 위 얼굴 줄(#14): 결과에 든 사람은 테두리 + 체크. 누르면 더하기/빼기 후 바로 다시 검색
  Widget faceRow(BuildContext context, List<Map<String, dynamic>> ps) {
    final cs = Theme.of(context).colorScheme;
    final on = {for (final w in words) ...ints(w['chosen'])};
    return SizedBox(
      height: MediaQuery.textScalerOf(context).scale(16) + 56, // 글자 1배에 약 72dp
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
        for (final p in ps)
          Semantics(
            key: ValueKey('face-${p['id']}'),
            button: true,
            selected: on.contains(p['id']),
            label: '${p['name']} ${on.contains(p['id']) ? '빼기' : '더하기'}',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => toggle(p['id'] as int),
              child: SizedBox(
                width: 56,
                child: Column(children: [
                  const SizedBox(height: 6),
                  Stack(clipBehavior: Clip.none, children: [
                    FaceAvatar(face: p['face'] as int?, label: p['name'] as String, size: 40),
                    if (on.contains(p['id'])) ...[
                      Positioned.fill(
                        child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: cs.primary, width: 2.5))),
                      ),
                      Positioned(
                        right: -3,
                        bottom: -3,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle, border: Border.all(color: cs.surface, width: 1.5)),
                          child: Icon(Icons.check, size: 10, color: cs.onPrimary),
                        ),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 4),
                  Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: on.contains(p['id']) ? FontWeight.w600 : null)),
                ]),
              ),
            ),
          ),
      ]),
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
    final ps = people.values.toList()..sort((a, b) => (b['n'] as int).compareTo(a['n'] as int));
    return CustomScrollView(slivers: [
      if (ps.isNotEmpty) SliverToBoxAdapter(child: faceRow(context, ps)),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (words.isNotEmpty || period != null) ...[
              Text(hint && words.isNotEmpty ? '이렇게 이해했어요 · 눌러서 바꿀 수 있어요' : '이렇게 이해했어요', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final w in words) personChip(context, w),
                if (period != null) periodChip(context, period!),
                if (rest.isNotEmpty)
                  Chip(label: Text('장면: $rest'), backgroundColor: cs.surfaceContainerHighest, side: BorderSide.none),
              ]),
              const SizedBox(height: 12),
            ],
            Text(error ?? (list.isEmpty
                    ? (period?['need'] == 'owner')
                        ? '누구 나이인지 위 칩을 눌러 골라 주세요.'
                        : '맞는 사진을 찾지 못했어요. 다른 말로 찾아보세요.'
                    : info),
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
