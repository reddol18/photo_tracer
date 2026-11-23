part of '../main.dart';

// ───────────────────────────── 홈: 시간 순서로 정리된 순간들. 인물 칩으로 그 사람이 나온 순간만

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onSearch});
  final VoidCallback? onSearch;

  /// 홈 탭이 보이는가(main.dart Shell이 탭을 옮길 때 바꾼다). 안 보일 때 인물이 바뀌면 표시만 해 두고 보일 때 읽는다(#29 A)
  static final visible = ValueNotifier<bool>(true);

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 빠른 이동 막대(#19)의 한 달: 지금 거르기에서 목록의 몇 번째부터(offset) 몇 개(n)
class _Month {
  const _Month(this.year, this.month, this.offset, this.n);
  final int year, month, offset, n;
  int get key => year * 12 + month;
  String get label => '$year년 $month월';
}

class _HomePageState extends State<HomePage> {
  static const page = 40;

  /// 순간이 이보다 적으면(한 화면 안팎) 빠른 이동 막대를 숨긴다
  static const barMinItems = 12;

  /// 불러온 순간들. 목록 전체의 [base]번째부터 이어진 한 덩어리(먼 곳으로 뛰면 그 자리부터 다시 쌓는다)
  final moments = <Map<String, dynamic>>[];
  int base = 0;

  /// 빠른 이동으로 뛴 자리(목록 전체 기준). 이 앞의 순간은 위로 자라는 목록에 둬서, 앞쪽을 불러와도 보던 자리가 밀리지 않는다
  int anchor = 0;
  bool jumped = false;
  List<_Month> months = [];
  List<Map<String, dynamic>> people = [];
  int? person; // 고른 인물, null이면 전체
  // 기간 거르기(#17): 인물과 함께 걸린다. 탭을 옮겨도 남고(IndexedStack이 상태를 둔다) 앱을 다시 켜면 풀린다
  PeriodPick? range;
  bool loading = false, loadingUp = false, end = false;
  int lastPeopleDone = -1;

  final scroll = ScrollController();
  final _stackKey = GlobalKey(), _headKey = GlobalKey(), _centerKey = GlobalKey();
  var _monthKeys = <int, GlobalKey>{}; // 화면에 그려진 월 머리글: 지금 보는 해를 찾는 데
  final barTop = ValueNotifier<double>(0); // 막대 윗변: 제목·칩 줄이 보이면 그 아래부터
  final current = ValueNotifier<int?>(null); // 지금 보는 달(_Month.key)
  final scrolling = ValueNotifier<bool>(false);
  Timer? _calm;

  late final settle = Debounced(onPeople);
  late final segSettle = Debounced(onSegments);
  bool dirty = false; // 숨어 있는 동안 인물이나 구간이 바뀌어 순간을 다시 읽어야 함

  @override
  void initState() {
    super.initState();
    Status.i.addListener(onStatus);
    peopleVersion.addListener(settle.call);
    segmentsVersion.addListener(segSettle.call);
    HomePage.visible.addListener(onVisible);
    reload();
  }

  @override
  void dispose() {
    Status.i.removeListener(onStatus);
    peopleVersion.removeListener(settle.call);
    segmentsVersion.removeListener(segSettle.call);
    HomePage.visible.removeListener(onVisible);
    settle.cancel();
    segSettle.cancel();
    _calm?.cancel();
    scroll.dispose();
    barTop.dispose();
    current.dispose();
    scrolling.dispose();
    super.dispose();
  }

  /// 얼굴 확인이 크게 늘었으면 다시 불러온다. 순간(구간)이 바뀐 것은 segmentsVersion(#31)이 따로 알린다 — 수가 같아도
  void onStatus() {
    final st = Status.i;
    final faces = (st.s?['faces_done'] as num?)?.toInt() ?? 0;
    if (lastPeopleDone >= 0 && !st.scanning && faces - lastPeopleDone > 500) reload();
  }

  /// 스캔이 구간을 바꾸면(#31: 사진 추가·삭제로 장 수·표지·순간 수가 바뀜) 순간을 제자리에서 다시 읽는다.
  /// 홈이 안 보이면 표시만 해 두고 보일 때 읽는다(인물과 같은 방식)
  void onSegments() {
    if (!mounted) return;
    dirty = true;
    if (HomePage.visible.value) refreshMoments();
  }

  int peopleSeq = 0; // onPeople 순번: 늦게 온 옛 목록이 덮지 않게

  /// 다른 곳에서 인물을 바꾸면(#27, #29 A) 인물 고르기 칩을 새로 읽고, 순간(카드의 이름·장 수·표지, 인물로 거른 목록)도 다시 읽는다.
  /// 고른 인물이 지워지거나 합쳐져 없어졌으면 전체로 돌린다. 홈이 안 보이면 순간은 표시만 해 두고 보일 때 읽는다
  Future<void> onPeople() async {
    final s = ++peopleSeq;
    try {
      final p = await loadPeople();
      if (!mounted || s != peopleSeq) return;
      final gone = person != null && !p.any((e) => e['id'] == person);
      setState(() {
        people = p..sort((a, b) => (b['n'] as int).compareTo(a['n'] as int));
        if (gone) person = null;
      });
      if (gone) {
        dirty = false;
        reload();
      } else {
        dirty = true;
        if (HomePage.visible.value) refreshMoments();
      }
    } catch (e) {
      debugPrint('홈 인물 목록 읽기 실패: $e');
    }
  }

  void onVisible() {
    if (HomePage.visible.value && dirty && mounted) refreshMoments();
  }

  /// 순간을 지금 불러온 범위 그대로 다시 읽어 제자리에서 바꾼다(맨 위로 튀지 않게, 뛴 자리 anchor도 그대로)
  Future<void> refreshMoments() async {
    dirty = false;
    final g = ++gen;
    loading = true;
    loadingUp = true;
    final count = moments.length < page ? page : moments.length;
    try {
      final list = await fetch(base, count);
      if (!mounted || g != gen) return;
      setState(() {
        moments
          ..clear()
          ..addAll(list);
        end = list.length < count;
      });
      loadMonths();
    } catch (e) {
      debugPrint('홈 순간 다시 읽기 실패: $e');
    } finally {
      if (g == gen) {
        loading = false;
        loadingUp = false;
      }
    }
  }

  Map<String, Object?> get filter => {'person': person, ...?range?.args};

  Future<void> reload() async {
    dirty = false;
    lastPeopleDone = (Status.i.s?['faces_done'] as num?)?.toInt() ?? 0;
    try {
      final p = await loadPeople();
      if (!mounted) return;
      final wasJumped = jumped;
      setState(() {
        people = p..sort((a, b) => (b['n'] as int).compareTo(a['n'] as int));
        moments.clear();
        base = 0;
        anchor = 0;
        jumped = false;
        end = false;
        gen++;
        loading = false;
        loadingUp = false;
      });
      if (wasJumped) _toTop();
      loadMonths();
      await more();
    } catch (_) {
    } finally {
      Launch.markHomeReady(); // 시작 화면(#21)은 홈 첫 목록까지 기다린다
    }
  }

  int gen = 0; // 거르기를 바꾸면 늘린다: 바꾸기 전에 보낸 요청의 답은 버린다

  /// 연·월 목차(#19). 없거나 실패하면 막대를 숨긴다
  Future<void> loadMonths() async {
    final g = gen;
    List<_Month> list = [];
    try {
      final r = await channel.invokeMethod('monthIndex', filter);
      list = [
        for (final e in (r as List? ?? const []))
          _Month((e['year'] as num).toInt(), (e['month'] as num).toInt(), (e['offset'] as num).toInt(), (e['n'] as num).toInt()),
      ];
    } catch (_) {}
    if (mounted && g == gen) setState(() => months = list);
  }

  Future<List<Map<String, dynamic>>> fetch(int offset, int limit) async {
    final r = await channel.invokeMethod('moments', {'offset': offset, 'limit': limit, ...filter});
    return (r as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// 아래로 이어 불러오기
  Future<void> more() async {
    if (loading || end) return;
    loading = true;
    final g = gen;
    try {
      final list = await fetch(base + moments.length, page);
      if (mounted && g == gen) {
        setState(() {
          moments.addAll(list);
          end = list.length < page;
        });
      }
    } finally {
      if (g == gen) loading = false;
    }
  }

  /// 빠른 이동으로 뛰어든 뒤 위로 올라가면 앞쪽을 불러온다(위로 자라는 목록에 붙어 보던 자리가 밀리지 않는다)
  Future<void> moreUp() async {
    if (loadingUp || base == 0) return;
    loadingUp = true;
    final g = gen;
    try {
      final from = (base - page).clamp(0, base);
      final list = await fetch(from, base - from);
      if (mounted && g == gen) {
        setState(() {
          moments.insertAll(0, list);
          // 그사이 목록이 줄었으면(정리 중) 더 위는 없다고 본다
          base = list.length == base - from ? from : 0;
        });
      }
    } finally {
      if (g == gen) loadingUp = false;
    }
  }

  // 막대를 끄는 동안 뛰기가 몰리면 마지막 것만: 앞의 불러오기가 끝나면 바로 다음 자리로
  _Month? _pending;
  bool _jumping = false;

  void jumpTo(_Month m) {
    _pending = m;
    current.value = m.key;
    if (!_jumping) _runJumps();
  }

  Future<void> _runJumps() async {
    _jumping = true;
    try {
      while (_pending != null && mounted) {
        final m = _pending!;
        _pending = null;
        await _jumpNow(m);
      }
    } finally {
      _jumping = false;
    }
  }

  /// 그 달 첫 순간이 맨 위(월 머리글)로 오게. 이미 불러온 범위면 그대로, 아니면 그 자리부터 다시 불러온다
  Future<void> _jumpNow(_Month m) async {
    final o = m.offset;
    if (o >= base && o < base + moments.length) {
      setState(() {
        anchor = o;
        jumped = true;
      });
      _toTop();
      return;
    }
    // 먼 곳: 새 자리의 첫 페이지가 올 때까지 앞 목록을 그대로 둔다(화면이 비거나 막대가 사라지지 않게).
    // 그동안 이어 불러오기(위·아래)는 막고, 답이 오면 한 번에 바꾼다
    final g = ++gen;
    loading = true;
    loadingUp = true;
    try {
      final list = await fetch(o, page);
      if (!mounted || g != gen) return;
      setState(() {
        moments
          ..clear()
          ..addAll(list);
        base = o;
        anchor = o;
        jumped = true;
        end = list.length < page;
      });
      _toTop();
    } catch (_) {
    } finally {
      if (g == gen) {
        loading = false;
        loadingUp = false;
      }
    }
  }

  void _toTop() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.jumpTo(0);
      });

  void pick(int? id) {
    if (person == id) return;
    setState(() => person = id);
    reload();
  }

  Future<void> openPeriod() async {
    final r = await showPeriodSheet(context, current: range);
    if (r == null || !mounted) return;
    setRange(r.pick);
  }

  void setRange(PeriodPick? p) {
    if (p == null && range == null) return;
    setState(() => range = p);
    reload();
  }

  Map<int, Map<String, dynamic>> get byId => {for (final p in people) p['id'] as int: p};

  bool get showBar => moments.isNotEmpty && months.map((m) => m.year).toSet().length >= 2 && months.fold(0, (s, m) => s + m.n) >= barMinItems;

  /// 스크롤할 때: 막대 위치(제목 아래)와 지금 보는 달을 맞추고, 막대를 잠시 또렷하게
  void _track() {
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || !stack.attached) return;
    final head = _headKey.currentContext?.findRenderObject() as RenderBox?;
    var top = 0.0;
    if (head != null && head.attached) {
      top = (head.localToGlobal(Offset(0, head.size.height), ancestor: stack).dy).clamp(0.0, stack.size.height);
    }
    barTop.value = top;
    // 윗변을 지난 머리글 중 가장 아래 것이 지금 달. 없으면 화면 안 첫 머리글의 바로 앞(더 최근) 달
    int? above, below;
    var aboveY = double.negativeInfinity, belowY = double.infinity;
    for (final e in _monthKeys.entries) {
      final ro = e.value.currentContext?.findRenderObject() as RenderBox?;
      if (ro == null || !ro.attached) continue;
      final y = ro.localToGlobal(Offset.zero, ancestor: stack).dy;
      if (y <= top + 24) {
        if (y > aboveY) (above, aboveY) = (e.key, y);
      } else if (y < belowY) {
        (below, belowY) = (e.key, y);
      }
    }
    int? cur = above;
    if (cur == null && below != null) {
      final i = months.indexWhere((m) => m.key == below);
      cur = i > 0 ? months[i - 1].key : below;
    }
    if (cur != null) current.value = cur;
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.metrics.pixels > n.metrics.maxScrollExtent - 800) more();
    if (jumped && base > 0 && n.metrics.pixels < n.metrics.minScrollExtent + 800) moreUp();
    if (n is ScrollUpdateNotification || n is ScrollStartNotification) {
      _calm?.cancel();
      scrolling.value = true;
    } else if (n is ScrollEndNotification) {
      _calm?.cancel();
      _calm = Timer(const Duration(milliseconds: 1200), () => scrolling.value = false);
    }
    _track();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final names = byId;
    final bar = showBar;
    // 달이 바뀔 때 '2026년 10월' 머리글. 순간마다 [머리글?, 카드] 묶음
    final units = <List<Widget>>[];
    final keys = <int, GlobalKey>{};
    int? month;
    for (final m in moments) {
      final d = DateTime.fromMillisecondsSinceEpoch(m['start'] as int);
      final k = d.year * 12 + d.month;
      final u = <Widget>[];
      if (k != month) {
        month = k;
        final gk = keys.containsKey(k) ? null : (keys[k] = _monthKeys[k] ?? GlobalKey());
        u.add(SectionLabel('${d.year}년 ${d.month}월', key: gk));
      }
      u.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: MomentCard(m, names: names, person: person, range: range)));
      units.add(u);
    }
    _monthKeys = keys;
    final a = (anchor - base).clamp(0, moments.length);
    final up = [for (final u in units.take(a)) ...u].reversed.toList();
    final down = [for (final u in units.skip(a)) ...u];
    final side = EdgeInsets.only(left: 16, right: bar ? _YearBar.width + 4 : 16); // 막대와 카드가 겹치지 않게
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _track();
    });
    final list = RefreshIndicator(
      onRefresh: () async {
        await Status.i.refresh(scan: true);
        await reload();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: CustomScrollView(controller: scroll, center: jumped ? _centerKey : null, slivers: [
          SliverToBoxAdapter(
            child: Column(key: _headKey, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PageTitle('추억', trailing: IconButton(tooltip: '검색', icon: const Icon(Icons.search), onPressed: widget.onSearch)),
              const NightBanner(),
              const FirstNightCard(),
              // 칩 줄: 맨 앞 '기간'(#17) + 전체/인물. 새 줄을 늘리지 않고 가로로 넘긴다. 큰 글씨면 줄 높이만 조금 는다
              if (people.isNotEmpty || moments.isNotEmpty || range != null)
                SizedBox(
                  height: 12 + (MediaQuery.textScalerOf(context).scale(20) + 16).clamp(40.0, 60.0),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    children: [
                      PeriodFilterChip(pick: range, onOpen: openPeriod, onClear: () => setRange(null)),
                      if (people.isNotEmpty) ...[
                        _PersonChip(label: '전체', on: person == null, onTap: () => pick(null)),
                        for (final p in people)
                          _PersonChip(label: p['name'] as String, face: p['face'] as int?, on: person == p['id'], onTap: () => pick(p['id'] as int)),
                      ],
                    ],
                  ),
                ),
            ]),
          ),
          if (moments.isEmpty && range != null && !loading)
            SliverToBoxAdapter(
              child: Padding(
                key: const ValueKey('period-empty'),
                padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
                child: Column(children: [
                  Icon(Icons.event_busy, size: 40, color: cs.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('맞는 순간이 없어요', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(person != null ? '${range!.label}에 이 사람이 나온 순간을 찾지 못했어요.' : '${range!.label}에 찍은 순간을 찾지 못했어요.',
                      textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, height: 1.5)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(onPressed: () => setRange(null), icon: const Icon(Icons.close), label: const Text('기간 풀기')),
                ]),
              ),
            )
          else if (moments.isEmpty && !jumped)
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
          // 빠른 이동으로 뛴 자리 앞의 순간들: 가운데(center) 위쪽에 놓여 위로 자란다(0번이 뛴 자리 바로 위)
          SliverPadding(padding: side, sliver: SliverList.list(children: up)),
          SliverPadding(key: _centerKey, padding: side.copyWith(bottom: 24), sliver: SliverList.list(children: down)),
        ]),
      ),
    );
    return Stack(key: _stackKey, children: [
      Positioned.fill(child: list),
      if (bar)
        Positioned.fill(
          child: _YearBar(
            key: const ValueKey('year-bar-host'),
            months: months,
            top: barTop,
            current: current,
            scrolling: scrolling,
            onJump: jumpTo,
          ),
        ),
    ]);
  }
}

/// 빠른 이동 막대(#19): 오른쪽 끝 연도 막대. 끌면 그 해·달로 뛰고 "2023년 12월" 말풍선, 누르면 그해 첫 달로.
/// 평소엔 흐리게, 스크롤하거나 끄는 동안 또렷하게. 막대 밖은 손대지 않는다(목록·카드·당겨서 새로고침은 그대로).
/// TalkBack에서는 "연도로 이동" 묶음 안의 해마다 버튼.
class _YearBar extends StatefulWidget {
  const _YearBar({super.key, required this.months, required this.top, required this.current, required this.scrolling, required this.onJump});
  static const width = 44.0; // 터치 영역 44dp
  final List<_Month> months;
  final ValueListenable<double> top;
  final ValueListenable<int?> current;
  final ValueListenable<bool> scrolling;
  final ValueChanged<_Month> onJump;

  @override
  State<_YearBar> createState() => _YearBarState();
}

class _YearBarState extends State<_YearBar> {
  static const pill = Color(0xFF2563EB), bubbleColor = Color(0xFF1B1C1F);
  _Month? dragging; // 끄는 중인 달(말풍선)
  double dragY = 0;
  double? frozenTop; // 끄는 동안 막대 윗변을 고정: 뛰면서 제목이 사라져도 손가락 아래 해가 바뀌지 않게
  bool hold = false; // 놓은 뒤 잠시 또렷하게
  Timer? _fade;

  List<int> get years => [for (final m in widget.months) m.year].fold<List<int>>([], (l, y) => l.isEmpty || l.last != y ? (l..add(y)) : l);

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  /// 막대 안 y → 해(칸을 고르게 나눔) → 그 칸 안 비율로 그해의 달(최근 달이 위)
  _Month at(double y, double h) {
    final ys = years;
    final slot = h / ys.length;
    final yi = (y / slot).floor().clamp(0, ys.length - 1);
    final ms = widget.months.where((m) => m.year == ys[yi]).toList();
    final f = ((y - yi * slot) / slot).clamp(0.0, 0.999);
    return ms[(f * ms.length).floor().clamp(0, ms.length - 1)];
  }

  _Month firstOf(int year) => widget.months.firstWhere((m) => m.year == year);

  final _barKey = GlobalKey(); // 해 칸들이 놓인 막대 상자

  /// 손가락의 화면 좌표 → 지금 막대 상자 안의 y와 막대 높이. 늘 지금 배치(RenderBox)로 잰다
  (double, double)? _local(Offset global) {
    final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final h = box.size.height;
    return (box.globalToLocal(global).dy.clamp(0.0, h), h);
  }

  void _drag(Offset global) {
    final p = _local(global);
    if (p == null) return;
    final m = at(p.$1, p.$2);
    setState(() {
      dragY = p.$1;
      dragging = m;
    });
    if (_jumped?.key != m.key) {
      _jumped = m;
      widget.onJump(m);
    }
  }

  _Month? _jumped; // 이번 끌기에서 마지막으로 뛴 달

  void _release() {
    _fade?.cancel();
    _jumped = null;
    setState(() {
      dragging = null;
      frozenTop = null;
      hold = true;
    });
    _fade = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => hold = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    return ValueListenableBuilder<double>(
      valueListenable: widget.top,
      builder: (context, liveTop, _) {
        final top = frozenTop ?? liveTop;
        return LayoutBuilder(builder: (context, c) {
          final h = (c.maxHeight - top - 8).clamp(0.0, double.infinity);
          if (h < 80) return const SizedBox.shrink(); // 제목·칩이 화면을 거의 차지하면 잠시 숨김
          return Stack(children: [
            Positioned(
              right: 0,
              top: top,
              width: _YearBar.width,
              height: h,
              child: ValueListenableBuilder<bool>(
                valueListenable: widget.scrolling,
                builder: (context, scrolling, child) => AnimatedOpacity(
                  opacity: scrolling || hold || dragging != null ? 1 : 0.35,
                  duration: const Duration(milliseconds: 200),
                  child: child,
                ),
                child: GestureDetector(
                  key: const ValueKey('year-bar'),
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTapUp: (d) {
                    final p = _local(d.globalPosition);
                    if (p != null) widget.onJump(firstOf(at(p.$1, p.$2).year));
                    _release();
                  },
                  // 끄는 동안은 막대 윗변을 고정한다: 뛰면서 제목·칩이 사라져도 손가락 아래 해가 그대로
                  onVerticalDragStart: (d) {
                    _fade?.cancel();
                    setState(() => frozenTop = top);
                    _drag(d.globalPosition);
                  },
                  onVerticalDragUpdate: (d) => _drag(d.globalPosition),
                  onVerticalDragEnd: (_) => _release(),
                  onVerticalDragCancel: _release,
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    label: '연도로 이동',
                    child: Container(
                      key: _barKey,
                      margin: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: ValueListenableBuilder<int?>(
                        valueListenable: widget.current,
                        builder: (context, cur, _) {
                          final on = dragging?.year ?? (cur == null ? null : (cur - 1) ~/ 12);
                          return Column(children: [
                            for (final y in years)
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  selected: y == on,
                                  label: '$y년',
                                  onTap: () => widget.onJump(firstOf(y)),
                                  child: ExcludeSemantics(
                                    child: Center(
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Container(
                                          key: ValueKey('bar-year-$y'),
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                          decoration: y == on ? BoxDecoration(color: pill, borderRadius: BorderRadius.circular(99)) : null,
                                          child: Text("'${(y % 100).toString().padLeft(2, '0')}",
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: y == on ? FontWeight.w700 : FontWeight.w600,
                                                color: y == on ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
                                              )),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ]);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (dragging != null)
              Positioned(
                right: _YearBar.width + 8,
                top: (top + dragY - scale.scale(15) / 2 - 10).clamp(top, top + h - 20),
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey('year-bubble'),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: bubbleColor, borderRadius: BorderRadius.circular(12)),
                    child: Text(dragging!.label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
          ]);
        });
      },
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
  const MomentCard(this.m, {super.key, required this.names, this.person, this.range});
  final Map<String, dynamic> m;
  final Map<int, Map<String, dynamic>> names;
  final int? person;
  final PeriodPick? range; // 기간으로 걸렀으면 순간 사진도 그 기간 안의 것만(#17)

  @override
  Widget build(BuildContext context) {
    final covers = (m['covers'] as List).map((e) => (e as num).toInt()).toList();
    final who = (m['people'] as List).map((e) => names[(e as num).toInt()]?['name'] as String?).nonNulls.toList();
    final n = m['n'] as int;
    final title = fmtRange(m['start'] as int, m['end'] as int);
    const gap = 3.0;
    final sub = '사진 ${fmtInt(n)}장${who.isEmpty ? '' : ' · ${who.join(', ')}'}';
    final cs = Theme.of(context).colorScheme;
    // 한 장뿐인 순간(지나가다 찍은 사진·흔들린 사진이 많다)은 한 줄로 작게: 큰 카드가 목록을 차지하지 않게
    if (n == 1 && covers.length == 1) {
      return Card(
        child: InkWell(
          onTap: () => showPhoto(context, covers.first),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 64, height: 64, child: Thumb(covers.first))),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text(sub, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
        ),
      );
    }
    Widget collage;
    if (covers.length >= 3) {
      collage = SizedBox(
        height: 180,
        // stretch: 사진이 칸 높이를 꽉 채우게 (기본 center면 세로 제약이 느슨해 가로 사진이 짧게 그려진다)
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
              // 장 수는 읽어 온 목록으로(#37): 보는 사이 사진을 지우면 줄고, 다 지우면 0장 + 빈 상태 문구
              subtitleOf: (k) => '사진 ${fmtInt(k ?? n)}장${who.isEmpty ? '' : ' · ${who.join(', ')}'}',
              empty: PhotosPage.emptyMoment,
              // 번호(id)는 스캔마다 다시 매겨진다: 표지 사진·시작~끝으로 지금 구간을 찾게 함께 넘긴다(#32)
              load: () => channel.invokeMethod('momentPhotos', {...momentKey(m['id'], covers.firstOrNull, m['start'], m['end']), 'person': person, ...?range?.args}),
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
