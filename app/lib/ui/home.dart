part of '../main.dart';

// ───────────────────────────── 홈: 시간 순서로 정리된 순간들. 인물 칩으로 그 사람이 나온 순간만

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onSearch});
  final VoidCallback? onSearch;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const page = 40;
  final moments = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> people = [];
  int? person; // 고른 인물, null이면 전체
  bool loading = false, end = false;
  int lastSegments = -1, lastPeopleDone = -1;

  @override
  void initState() {
    super.initState();
    Status.i.addListener(onStatus);
    reload();
  }

  @override
  void dispose() {
    Status.i.removeListener(onStatus);
    super.dispose();
  }

  /// 갤러리를 다시 읽어 순간이 바뀌었거나 얼굴 확인이 크게 늘었으면 다시 불러온다
  void onStatus() {
    final st = Status.i;
    final seg = st.segments, faces = (st.s?['faces_done'] as num?)?.toInt() ?? 0;
    if (lastSegments >= 0 && !st.scanning && (seg != lastSegments || faces - lastPeopleDone > 500)) reload();
  }

  Future<void> reload() async {
    lastSegments = Status.i.segments;
    lastPeopleDone = (Status.i.s?['faces_done'] as num?)?.toInt() ?? 0;
    try {
      final p = await loadPeople();
      if (!mounted) return;
      setState(() {
        people = p..sort((a, b) => (b['n'] as int).compareTo(a['n'] as int));
        moments.clear();
        end = false;
      });
      await more();
    } catch (_) {}
  }

  Future<void> more() async {
    if (loading || end) return;
    loading = true;
    try {
      final r = await channel.invokeMethod('moments', {'offset': moments.length, 'limit': page, 'person': person});
      final list = (r as List).map((e) => Map<String, dynamic>.from(e)).toList();
      if (mounted) {
        setState(() {
          moments.addAll(list);
          end = list.length < page;
        });
      }
    } finally {
      loading = false;
    }
  }

  void pick(int? id) {
    if (person == id) return;
    setState(() => person = id);
    reload();
  }

  Map<int, Map<String, dynamic>> get byId => {for (final p in people) p['id'] as int: p};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final names = byId;
    // 달이 바뀔 때 '2026년 10월' 머리글
    final rows = <Widget>[];
    String? month;
    for (final m in moments) {
      final d = DateTime.fromMillisecondsSinceEpoch(m['start'] as int);
      final key = '${d.year}년 ${d.month}월';
      if (key != month) {
        month = key;
        rows.add(SectionLabel(key));
      }
      rows.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: MomentCard(m, names: names, person: person)));
    }
    return RefreshIndicator(
      onRefresh: () async {
        await Status.i.refresh(scan: true);
        await reload();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 800) more();
          return false;
        },
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: PageTitle('추억', trailing: IconButton(tooltip: '검색', icon: const Icon(Icons.search), onPressed: widget.onSearch)),
          ),
          const SliverToBoxAdapter(child: NightBanner()),
          const SliverToBoxAdapter(child: FirstNightCard()),
          if (people.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    _PersonChip(label: '전체', on: person == null, onTap: () => pick(null)),
                    for (final p in people)
                      _PersonChip(label: p['name'] as String, face: p['face'] as int?, on: person == p['id'], onTap: () => pick(p['id'] as int)),
                  ],
                ),
              ),
            ),
          if (moments.isEmpty)
            SliverToBoxAdapter(
              child: ListenableBuilder(
                listenable: Status.i,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    !Status.i.ready || loading
                        ? ''
                        : person != null
                            ? '아직 이 사람이 나온 순간을 찾지 못했어요.\n정리가 진행되면 늘어나요.'
                            : Status.i.scanning
                                ? '사진 목록을 읽고 있어요…'
                                : Status.i.permission
                                    ? '아직 사진이 없어요.'
                                    : '사진 보기를 허용하면 여기에 순간들이 나와요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant, height: 1.6),
                  ),
                ),
              ),
            ),
          SliverPadding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), sliver: SliverList.list(children: rows)),
        ]),
      ),
    );
  }
}

class _PersonChip extends StatelessWidget {
  const _PersonChip({required this.label, this.face, required this.on, required this.onTap});
  final String label;
  final int? face;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        selected: on,
        button: true,
        child: Material(
          color: on ? cs.primary : Theme.of(context).cardTheme.color,
          shape: StadiumBorder(side: BorderSide(color: on ? cs.primary : cs.outlineVariant)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(face == null && label == '전체' ? 14 : 4, 4, 14, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (label != '전체') ...[FaceAvatar(face: face, label: label, size: 28), const SizedBox(width: 6)],
                Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: on ? cs.onPrimary : cs.onSurface)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 순간 하나: 사진 1~3장 모음 + 날짜 + "사진 48장 · 엄마, 딸"
class MomentCard extends StatelessWidget {
  const MomentCard(this.m, {super.key, required this.names, this.person});
  final Map<String, dynamic> m;
  final Map<int, Map<String, dynamic>> names;
  final int? person;

  @override
  Widget build(BuildContext context) {
    final covers = (m['covers'] as List).map((e) => (e as num).toInt()).toList();
    final who = (m['people'] as List).map((e) => names[(e as num).toInt()]?['name'] as String?).nonNulls.toList();
    final n = m['n'] as int;
    final title = fmtRange(m['start'] as int, m['end'] as int);
    const gap = 3.0;
    Widget collage;
    if (covers.length >= 3) {
      collage = SizedBox(
        height: 180,
        child: Row(children: [
          Expanded(flex: 2, child: Thumb(covers[0], size: 512)),
          const SizedBox(width: gap),
          Expanded(
            child: Column(children: [
              Expanded(child: SizedBox(width: double.infinity, child: Thumb(covers[1]))),
              const SizedBox(height: gap),
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  Thumb(covers[2]),
                  if (n > 3)
                    Container(
                      color: Colors.black38,
                      alignment: Alignment.center,
                      child: Text('+${fmtInt(n - 3)}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      );
    } else {
      collage = SizedBox(
        height: covers.length == 1 ? 200 : 150,
        child: Row(children: [
          for (var i = 0; i < covers.length; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            Expanded(child: Thumb(covers[i], size: 512)),
          ],
        ]),
      );
    }
    return Card(
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PhotosPage(
              title: title,
              subtitle: '사진 ${fmtInt(n)}장${who.isEmpty ? '' : ' · ${who.join(', ')}'}',
              load: () => channel.invokeMethod('momentPhotos', {'id': m['id'], 'person': person}),
            ),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (covers.isNotEmpty) collage,
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text('사진 ${fmtInt(n)}장${who.isEmpty ? '' : ' · ${who.join(', ')}'}',
                  style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}
