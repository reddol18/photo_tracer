part of '../main.dart';

// ───────────────────────────── 인물
// 등록한 인물: 사용자가 고른 얼굴과 닮은 얼굴을 찾는다(Who.kt). 자동 묶음(자주 보이는 얼굴)은 새 인물을 등록할 때만 쓴다.

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  List<Map<String, dynamic>>? people;
  List<Map<String, dynamic>> unknown = []; // 아직 등록 안 한 사람의 자동 묶음
  int review = 0; // '이 사람 맞나요?' 남은 수
  final selected = <int>[]; // 길게 눌러 고른 등록 인물(합치기). 처음 고른 인물로 합친다

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final p = await loadPeople();
      final c = ((await channel.invokeMethod('persons')) as List).map((e) => Map<String, dynamic>.from(e)).toList();
      final r = Map<String, dynamic>.from(await channel.invokeMethod('reviewQueue', {'limit': 1}) as Map);
      if (!mounted) return;
      setState(() {
        people = p..sort((a, b) => (b['n'] as int).compareTo(a['n'] as int));
        unknown = c.where((e) => e['known'] != true).toList();
        review = (r['total'] as num).toInt();
      });
    } catch (_) {
      if (mounted) setState(() => people ??= []);
    }
  }

  Future<void> merge() async {
    final names = {for (final p in people!) p['id'] as int: personLabel(p)};
    final ok = await confirm(context, '${selected.length}명을 한 사람으로 합칠까요?',
        '같은 사람을 두 번 등록했을 때 써요. 모두 "${names[selected.first]}"(으)로 모아요.', ok: '합치기');
    if (!ok) return;
    await channel.invokeMethod('whoMerge', {'ids': selected});
    setState(selected.clear);
    load();
  }

  void toggle(int id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id));

  Future<void> open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    load();
  }

  /// 자주 보이는 얼굴 한 묶음을 열어 얼굴을 누르면 등록한다
  Future<void> openCluster(Map<String, dynamic> c) => open(PhotosPage(
        title: '이 얼굴이 나온 사진',
        subtitle: '사진을 열고 얼굴을 눌러 이름을 붙여 주세요',
        load: () => channel.invokeMethod('personPhotos', {'id': c['id']}),
      ));

  @override
  Widget build(BuildContext context) {
    final p = people;
    if (p == null) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: load,
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: selected.isEmpty
              ? PageTitle('인물',
                  trailing: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: () => open(const ClustersPage()),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('인물 추가'),
                  ))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
                  child: Row(children: [
                    IconButton(tooltip: '고르기 그만', icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
                    Expanded(child: Text('${selected.length}명 고름', style: Theme.of(context).textTheme.titleMedium)),
                    FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(0, 40)), onPressed: selected.length >= 2 ? merge : null, child: const Text('합치기')),
                  ]),
                ),
        ),
        if (review > 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Material(
                color: cs.primary,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => open(const ReviewPage()),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('이 사람 맞나요? ${fmtInt(review)}장', style: TextStyle(color: cs.onPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text('확인해 주시면 다음 정리가 더 정확해져요', style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.9), fontSize: 13)),
                        ]),
                      ),
                      Icon(Icons.chevron_right, color: cs.onPrimary),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        if (unknown.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Expanded(child: Text('자주 보이는 얼굴', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
                      TextButton(onPressed: () => open(const ClustersPage()), child: const Text('모두 보기')),
                    ]),
                    Text('이름을 붙이면 그 사람 사진을 모아 드려요', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 84,
                      child: ListView(scrollDirection: Axis.horizontal, children: [
                        for (final c in unknown.take(10))
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => openCluster(c),
                              child: Column(children: [
                                FaceAvatar(face: c['face'] as int, size: 56),
                                const SizedBox(height: 6),
                                Text('${fmtInt(c['n'])}장', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                              ]),
                            ),
                          ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: SectionLabel(p.isEmpty ? '등록한 인물' : '등록한 인물 ${p.length}명'),
          ),
        ),
        if (p.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Text(
                unknown.isEmpty
                    ? '아직 등록한 인물이 없어요. 정리가 진행되면 자주 보이는 얼굴이 위에 나와요. 사진을 크게 보고 얼굴을 눌러 바로 등록할 수도 있어요.'
                    : '위의 자주 보이는 얼굴을 눌러 가족부터 등록해 보세요.',
                style: TextStyle(color: cs.onSurfaceVariant, height: 1.6),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          sliver: SliverGrid(
            // 칸 높이 = 얼굴 + 이름 두 줄. 글자 크기를 키워도 넘치지 않게 글자 높이로 잰다
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, mainAxisSpacing: 16, crossAxisSpacing: 12,
                mainAxisExtent: 84 + 8 + MediaQuery.textScalerOf(context).scale(15 + 12) * 1.5 + 6),
            delegate: SliverChildBuilderDelegate(childCount: p.length, (context, i) {
              final id = p[i]['id'] as int;
              final on = selected.contains(id);
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => selected.isNotEmpty ? toggle(id) : open(WhoPage(id: id)),
                onLongPress: () => toggle(id),
                child: Column(children: [
                  Stack(alignment: Alignment.center, children: [
                    FaceAvatar(face: p[i]['face'] as int?, label: p[i]['name'] as String, size: 84),
                    if (on)
                      Container(
                        width: 84, height: 84,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black38, border: Border.all(color: cs.primary, width: 3)),
                        alignment: Alignment.center,
                        child: Text('${selected.indexOf(id) + 1}', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                      ),
                  ]),
                  const SizedBox(height: 8),
                  Text(p[i]['name'] as String, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('${p[i]['relation'] != null && p[i]['relation'] != p[i]['name'] ? '${p[i]['relation']} · ' : ''}${fmtInt(p[i]['n'])}장',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              );
            }),
          ),
        ),
        if (p.length >= 2 && selected.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Text('같은 사람을 두 번 등록했다면 길게 눌러 골라 합칠 수 있어요.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ),
          ),
      ]),
    );
  }
}

/// 자주 보이는 얼굴 모두 보기 (자동 묶음). 다시 묶기·이미 등록한 사람의 묶음도 여기
class ClustersPage extends StatefulWidget {
  const ClustersPage({super.key});

  @override
  State<ClustersPage> createState() => _ClustersPageState();
}

class _ClustersPageState extends State<ClustersPage> {
  List<Map<String, dynamic>>? clusters;
  Map<String, dynamic>? info;
  Timer? ticker;
  bool showKnown = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final c = await channel.invokeMethod('persons');
    final i = Map<String, dynamic>.from(await channel.invokeMethod('clusterInfo') as Map);
    if (!mounted) return;
    setState(() {
      clusters = (c as List).map((e) => Map<String, dynamic>.from(e)).toList();
      info = i;
    });
    if ((i['running'] as num) > 0) watch(); // 다른 화면에 갔다 와도 묶는 중이면 진행을 이어 보여 준다
  }

  /// 다시 묶기 예상 시간(ms): 지난번 처음부터 묶은 시간을 얼굴 수에 비례해 늘린다. 기록이 없으면 null
  int? estimateMs(Map<String, dynamic> i) {
    final ms = i['full_ms'] as int, n = i['full_faces'] as int;
    return ms > 0 && n > 0 ? (ms * (i['faces'] as int) / n).round() : null;
  }

  String fmtDuration(int ms) => ms < 5000 ? '몇 초' : ms < 90000 ? '약 ${(ms / 1000).round()}초' : '약 ${(ms / 60000).round()}분';

  Future<void> recluster() async {
    final i = info!;
    final est = estimateMs(i);
    final ok = await confirm(context, '얼굴을 처음부터 다시 묶을까요?',
        '묶음이 이상할 때 써요. 등록한 인물과 직접 고른 얼굴은 그대로 둬요.\n\n'
        '걸리는 시간: ${est != null ? fmtDuration(est) : '얼굴이 ${fmtInt(i['faces'])}개라 몇 분 걸릴 수 있어요'}\n'
        '다른 화면으로 가도 계속해요.', ok: '다시 묶기');
    if (!ok) return;
    channel.invokeMethod('recluster'); // 기다리지 않는다 — 끝났는지는 watch가 clusterInfo로 본다
    setState(() => info = {...i, 'running': DateTime.now().millisecondsSinceEpoch});
    watch();
  }

  void watch() {
    ticker ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      final i = Map<String, dynamic>.from(await channel.invokeMethod('clusterInfo') as Map);
      if (!mounted) return;
      if ((i['running'] as num) == 0) {
        ticker?.cancel();
        ticker = null;
        load();
      } else {
        setState(() => info = i);
      }
    });
  }

  Widget grid(List<Map<String, dynamic>> c) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4, mainAxisSpacing: 12, crossAxisSpacing: 10,
              mainAxisExtent: (MediaQuery.sizeOf(context).width - 32 - 30) / 4 + 4 + MediaQuery.textScalerOf(context).scale(12) * 1.5 + 4),
          delegate: SliverChildBuilderDelegate(childCount: c.length, (context, i) {
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(
                    builder: (_) => PhotosPage(
                          title: '이 얼굴이 나온 사진',
                          subtitle: '사진을 열고 얼굴을 눌러 이름을 붙여 주세요',
                          load: () => channel.invokeMethod('personPhotos', {'id': c[i]['id']}),
                        )));
                load();
              },
              child: Column(children: [
                AspectRatio(aspectRatio: 1, child: ClipOval(child: Thumb(c[i]['face'] as int, face: true))),
                const SizedBox(height: 4),
                Text('${fmtInt(c[i]['n'])}장', style: Theme.of(context).textTheme.bodySmall),
              ]),
            );
          }),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = clusters, i = info;
    final cs = Theme.of(context).colorScheme;
    final busy = i != null && (i['running'] as num) > 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('자주 보이는 얼굴'),
        actions: [
          if (i != null) IconButton(tooltip: '처음부터 다시 묶기', icon: const Icon(Icons.refresh), onPressed: busy ? null : recluster),
        ],
      ),
      body: c == null || i == null
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Text('비슷한 얼굴끼리 모아 둔 것이에요. 묶음을 열고 사진 속 얼굴을 눌러 이름을 붙이면, 그 얼굴과 닮은 사진을 찾아 드려요. '
                      '아이들끼리는 섞일 수 있어요.', style: TextStyle(color: cs.onSurfaceVariant, height: 1.5)),
                ),
              ),
              if (busy)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Bar(() {
                        final est = estimateMs(i);
                        final elapsed = DateTime.now().millisecondsSinceEpoch - (i['running'] as num).toInt();
                        return est != null && est > 0 ? (elapsed / est).clamp(0.0, 0.95) : null;
                      }()),
                      const SizedBox(height: 8),
                      Text('다시 묶는 중이에요. 끝나면 새 묶음이 보여요.', style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                ),
              grid(c.where((e) => e['known'] != true).toList()),
              // 얼굴 절반 이상이 이미 등록한 인물인 묶음은 접어 둔다 — 새로 등록할 사람을 찾기 쉽게(#6)
              SliverToBoxAdapter(
                child: ListTile(
                  leading: Icon(showKnown ? Icons.expand_less : Icons.expand_more),
                  title: Text('이미 등록한 사람의 묶음 ${c.where((e) => e['known'] == true).length}개'),
                  onTap: () => setState(() => showKnown = !showKnown),
                ),
              ),
              if (showKnown) grid(c.where((e) => e['known'] == true).toList()),
            ]),
    );
  }
}

// ───────────────────────────── 등록한 인물 한 명

class WhoPage extends StatefulWidget {
  const WhoPage({super.key, required this.id});
  final int id;

  @override
  State<WhoPage> createState() => _WhoPageState();
}

class _WhoPageState extends State<WhoPage> {
  static const kinds = {'all': '전체', 'ref': '직접 고른 사진', 'found': '찾은 사진', 'maybe': '맞는지 확인'};
  List<Map<String, dynamic>>? photos; // id, face, sim, kind
  Map<String, dynamic> person = {'name': ''}; // name, relation, birth_year
  String get name => person['name'] as String;
  String kind = 'all';
  int? year; // 찍은 해로 거르기. null: 모든 해, 0: 찍은 날 모름
  bool lowFirst = false; // 확실하지 않은 것부터 (잘못 찾은 사진 먼저)

  static int yearOf(Map<String, dynamic> p) => p['taken'] == null ? 0 : DateTime.fromMillisecondsSinceEpoch(p['taken'] as int).year;
  bool kindOk(Map<String, dynamic> p, String k) => k == 'all' || p['kind'] == k;
  bool yearOk(Map<String, dynamic> p, int? y) => y == null || yearOf(p) == y;
  final selected = <int>{};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await channel.invokeMethod('whoPhotos', {'id': widget.id});
    final p = await loadPeople();
    if (!mounted) return;
    setState(() {
      photos = (r as List).map((e) => Map<String, dynamic>.from(e)).toList();
      person = p.firstWhere((e) => e['id'] == widget.id, orElse: () => {'name': ''});
    });
  }

  List<Map<String, dynamic>> get shown {
    final list = photos!.where((p) => kindOk(p, kind) && yearOk(p, year)).toList();
    if (lowFirst) list.sort((a, b) => (a['sim'] as num).compareTo(b['sim'] as num));
    return list;
  }

  Future<void> act(String method, Iterable<int> ids) async {
    await channel.invokeMethod(method, {'id': widget.id, 'photos': ids.toList()});
    setState(selected.clear);
    await load();
  }

  void toggle(int id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id));

  Future<void> menu(String v) async {
    if (v == 'edit') {
      final n = await askPerson(context, '인물 정보', person);
      if (n != null) { await channel.invokeMethod('whoUpdate', {...n, 'id': widget.id}); load(); }
    } else if (v == 'sort') {
      setState(() => lowFirst = !lowFirst);
    } else if (v == 'delete') {
      if (await confirm(context, '"$name"을(를) 지울까요?', '이 사람으로 찾은 기록을 지워요. 사진은 지우지 않아요.', ok: '지우기', danger: true)) {
        await channel.invokeMethod('whoDelete', {'id': widget.id});
        if (mounted) Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = photos == null ? null : shown;
    final all = photos ?? [];
    final cs = Theme.of(context).colorScheme;
    // 개수는 서로 걸러서: 종류 칩은 고른 해 안에서, 연도 칩은 고른 종류 안에서
    final count = {for (final k in kinds.keys) k: all.where((p) => kindOk(p, k) && yearOk(p, year)).length};
    final byYear = <int, int>{};
    for (final p in all.where((p) => kindOk(p, kind))) {
      byYear.update(yearOf(p), (n) => n + 1, ifAbsent: () => 1);
    }
    if (year != null) byYear.putIfAbsent(year!, () => 0); // 종류를 바꿔 0장이 돼도 고른 칩은 남긴다
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a)); // 최근 해부터, 모름(0)은 맨 뒤
    final birth = person['birth_year'] as int?;
    String yearLabel(int y) => y == 0 ? '날짜 모름' : birth != null && y >= birth ? '$y · ${y - birth}살' : '$y';
    return Scaffold(
      appBar: selected.isEmpty
          ? AppBar(
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(personLabel(person)),
                Text('사진 ${fmtInt(all.length)}장${birth != null ? ' · $birth년생' : ''}', style: Theme.of(context).textTheme.bodySmall),
              ]),
              actions: [
                PopupMenuButton<String>(onSelected: menu, itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('이름·관계·태어난 해 고치기')),
                  PopupMenuItem(value: 'sort', child: Text(lowFirst ? '날짜순으로 보기' : '확실하지 않은 사진부터 보기')),
                  const PopupMenuItem(value: 'delete', child: Text('인물 지우기')),
                ]),
              ],
            )
          : AppBar(
              leading: IconButton(tooltip: '고르기 그만', icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
              title: Text('${selected.length}장 고름'),
              actions: [
                TextButton(onPressed: () => act('whoConfirm', selected), child: const Text('이 사람 맞아요')),
                TextButton(onPressed: () => act('whoReject', selected), child: const Text('아니에요')),
              ],
            ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(children: [
                  for (final k in kinds.keys)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text('${kinds[k]} ${count[k]}'), selected: kind == k, onSelected: (_) => setState(() => kind = k)),
                    ),
                ]),
              ),
              // 찍은 해별로: 해마다 얼굴을 몇 개씩 골라 주면 자라는 아이도 잘 찾는다. 생년이 있으면 그해 나이도
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(children: [
                  for (final y in [null, ...years.where((y) => y != 0), if (byYear.containsKey(0)) 0])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(y == null ? '모든 해' : '${yearLabel(y)} (${byYear[y]})'),
                        visualDensity: VisualDensity.compact,
                        selected: year == y,
                        onSelected: (_) => setState(() => year = y),
                      ),
                    ),
                ]),
              ),
              if (kind == 'maybe' && list.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text('길게 눌러 여러 장을 골라 한 번에 맞다·아니다를 알려 줄 수 있어요.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final it = list[i];
                    final id = it['id'] as int;
                    return GestureDetector(
                      onTap: () async {
                        if (selected.isNotEmpty) return toggle(id);
                        await showPhoto(context, id, who: widget.id, ids: [for (final e in list) e['id'] as int]);
                        load();
                      },
                      onLongPress: () => toggle(id),
                      child: Stack(fit: StackFit.expand, children: [
                        Thumb(id),
                        if (it['kind'] != 'found')
                          Positioned(right: 3, top: 3, child: KindBadge(it['kind'] as String)),
                        if (selected.contains(id))
                          Container(color: Colors.black45, child: const Icon(Icons.check_circle, color: Colors.white, size: 32)),
                      ]),
                    );
                  },
                ),
              ),
            ]),
    );
  }
}

/// 사진 귀퉁이 표시: 직접 고름(✓) · 확인 필요(?)
class KindBadge extends StatelessWidget {
  const KindBadge(this.kind, {super.key});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final ref = kind == 'ref';
    return Container(
      width: 20, height: 20,
      decoration: BoxDecoration(shape: BoxShape.circle, color: ref ? Theme.of(context).colorScheme.primary : Colors.white),
      child: ref
          ? const Icon(Icons.check, size: 14, color: Colors.white, semanticLabel: '직접 고름')
          : const Center(child: Text('?', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
    );
  }
}
