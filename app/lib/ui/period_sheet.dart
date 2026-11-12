part of '../main.dart';

// ───────────────────────────── 기간 거르기(#17): 홈·검색 결과가 함께 쓰는 '기간' 칩과 아래에서 올라오는 시트
// 날짜 계산은 하지 않는다. 고른 달·나이를 Kotlin "period"(When.sheet)에 보내 기간(from~to ms)과 표시 글을 받는다.
// 그래서 나이 → 기간은 검색어 "딸 3살 때"(#16 When.Age)와 같은 규칙 한곳에서 나온다.

/// 고른 기간. from~to(ms, 양 끝 포함), range("2023년", "2023.3~2023.8"), 나이로 골랐으면 who(인물 이름)·age("1~2살")
class PeriodPick {
  const PeriodPick({required this.from, required this.to, required this.range, this.age, this.who, required this.sel});
  final int from, to;
  final String range;
  final String? age, who;
  final Map<String, dynamic> sel; // 시트를 다시 열 때 고른 것을 되살리기(kind months: y1 m1 y2 m2 / age: person a b)

  /// 칩 글: "2023년" / "2023.3~2023.8" / "딸 1~2살"
  String get label => age == null ? range : '${who ?? ''} $age'.trim();

  Map<String, int> get args => {'from': from, 'to': to};
}

/// 나이 칩: Kotlin When.Age의 kind·n과 같은 말
final periodAges = <({String kind, int n, String label})>[
  (kind: '백일', n: 0, label: '백일'),
  (kind: '돌', n: 0, label: '돌'),
  for (var n = 1; n <= 10; n++) (kind: '살', n: n, label: '$n살'),
  (kind: '유치원', n: 0, label: '유치원'),
  (kind: '초등', n: 0, label: '초등학생'),
  (kind: '중등', n: 0, label: '중학생'),
  (kind: '고등', n: 0, label: '고등학생'),
];

/// 시트 열기. 닫으면 null, '풀기'면 (pick: null), 고르면 (pick: 고른 기간).
/// ageTab: 나이 탭으로 열기, ageWho·ageLabel: 검색어에서 읽은 나이(#16 "딸 1살 때")가 있으면 그 인물·나이를 미리 고른다
Future<({PeriodPick? pick})?> showPeriodSheet(BuildContext context,
        {PeriodPick? current, bool ageTab = false, String? ageWho, String? ageLabel}) =>
    showModalBottomSheet<({PeriodPick? pick})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PeriodSheet(current: current, ageTab: ageTab, ageWho: ageWho, ageLabel: ageLabel),
    );

class PeriodSheet extends StatefulWidget {
  const PeriodSheet({super.key, this.current, this.ageTab = false, this.ageWho, this.ageLabel});
  final PeriodPick? current;
  final bool ageTab;
  final String? ageWho, ageLabel;

  @override
  State<PeriodSheet> createState() => _PeriodSheetState();
}

class _PeriodSheetState extends State<PeriodSheet> with SingleTickerProviderStateMixin {
  late final TabController tabs;
  List<({int year, int n})> years = [];
  List<Map<String, dynamic>> born = []; // 생년을 넣은 인물
  bool loaded = false;
  // 연도·기간 탭: 시작 달 ~ 끝 달
  int? y1, m1, y2, m2;
  // 인물 나이 탭: 누구, 나이 칩 두 개(순번)
  int? who, a, b;
  PeriodPick? result; // 지금 고른 것의 기간(Kotlin이 계산한)
  int asked = 0; // 늦게 온 답은 버린다

  @override
  void initState() {
    super.initState();
    final sel = widget.current?.sel;
    final age = widget.ageTab || sel?['kind'] == 'age';
    tabs = TabController(length: 2, vsync: this, initialIndex: age ? 1 : 0)..addListener(onTab);
    if (sel?['kind'] == 'months') {
      y1 = sel!['y1']; m1 = sel['m1']; y2 = sel['y2']; m2 = sel['m2'];
    } else if (sel?['kind'] == 'age') {
      who = sel!['person']; a = sel['a']; b = sel['b'];
    } else if (widget.ageLabel != null) {
      final i = periodAges.indexWhere((e) => e.label == widget.ageLabel);
      if (i >= 0) a = i;
    }
    load();
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final r = (await channel.invokeMethod('yearCounts')) as List? ?? [];
      final ps = await loadPeople();
      if (!mounted) return;
      setState(() {
        years = [for (final e in r) (year: (e['year'] as num).toInt(), n: (e['n'] as num).toInt())];
        born = ps.where((p) => p['birth_year'] != null).toList()..sort((x, y) => (y['n'] as int).compareTo(x['n'] as int));
        who ??= born.where((p) => p['name'] == widget.ageWho).firstOrNull?['id'] as int? ?? (born.length == 1 ? born.first['id'] as int : null);
        loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => loaded = true);
    }
    resolve();
  }

  void onTab() {
    if (!tabs.indexIsChanging) resolve();
  }

  bool get ageMode => tabs.index == 1;

  Map<String, dynamic>? get person => born.where((p) => p['id'] == who).firstOrNull;

  /// 지금 탭에서 고른 것을 Kotlin에 보내 기간으로 바꾼다
  Future<void> resolve() async {
    final n = ++asked;
    Map<String, dynamic>? args;
    if (ageMode) {
      final p = person;
      if (p != null && a != null) {
        final lo = b == null ? a! : (a! < b! ? a! : b!), hi = b == null ? a! : (a! < b! ? b! : a!);
        Map<String, dynamic> age(int i) => {'kind': periodAges[i].kind, 'n': periodAges[i].n};
        args = {'kind': 'age', 'birth': p['birth_year'], 'a': age(lo), 'b': age(hi)};
      }
    } else if (y1 != null && m1 != null && y2 != null && m2 != null) {
      args = {'kind': 'months', 'y1': y1, 'm1': m1, 'y2': y2, 'm2': m2};
    }
    if (args == null) {
      setState(() => result = null);
      return;
    }
    try {
      final r = Map<String, dynamic>.from(await channel.invokeMethod('period', args));
      if (!mounted || n != asked) return;
      setState(() => result = PeriodPick(
            from: (r['from'] as num).toInt(),
            to: (r['to'] as num).toInt(),
            range: r['range'] as String,
            age: r['age'] as String?,
            who: ageMode ? person!['name'] as String : null,
            sel: ageMode ? {'kind': 'age', 'person': who, 'a': a, 'b': b} : {'kind': 'months', 'y1': y1, 'm1': m1, 'y2': y2, 'm2': m2},
          ));
    } catch (_) {
      if (mounted && n == asked) setState(() => result = null);
    }
  }

  void pickYear(int y) {
    setState(() { y1 = y; m1 = 1; y2 = y; m2 = 12; });
    resolve();
  }

  void pickAge(int i) {
    setState(() {
      if (a == null || b != null) {
        a = i; b = null;
      } else if (a == i) {
        a = null;
      } else {
        b = i;
      }
    });
    resolve();
  }

  int? get pickedYear => y1 != null && y1 == y2 && m1 == 1 && m2 == 12 ? y1 : null;

  String ym(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}년 ${d.month}월';
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('기간으로 거르기', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          ),
          TabBar(controller: tabs, tabs: const [Tab(text: '연도 · 기간'), Tab(text: '인물 나이')]),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: AnimatedBuilder(animation: tabs, builder: (context, _) => ageMode ? ageTab(context) : yearTab(context)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(context, (pick: null)),
                child: const Text('풀기'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('period-apply'),
                  onPressed: r == null ? null : () => Navigator.pop(context, (pick: r)),
                  child: Text(r == null ? '보기' : '${r.label} 보기', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget yearTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 고를 수 있는 해: 사진이 있는 해의 처음~끝(이미 고른 해도 넣는다 — 해 목록을 읽기 전에 다시 열었을 때)
    final all = [...years.map((e) => e.year), ?y1, ?y2];
    final now = DateTime.now().year;
    final lo = all.isEmpty ? now : all.reduce((x, y) => x < y ? x : y), hi = all.isEmpty ? now : all.reduce((x, y) => x > y ? x : y);
    final yearList = [for (var y = hi; y >= lo; y--) y];
    Widget monthPick(String label, int? y, int? m, void Function(int y, int m) set) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(width: 36, child: Text(label, style: TextStyle(color: cs.onSurfaceVariant))),
            DropdownButton<int>(
              value: y,
              hint: const Text('년'),
              items: [for (final v in yearList) DropdownMenuItem(value: v, child: Text('$v년'))],
              onChanged: (v) => set(v!, m ?? 1),
            ),
            DropdownButton<int>(
              value: m,
              hint: const Text('월'),
              items: [for (var v = 1; v <= 12; v++) DropdownMenuItem(value: v, child: Text('$v월'))],
              onChanged: (v) => set(y ?? hi, v!),
            ),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (loaded && years.isEmpty)
        Text('날짜가 있는 사진이 아직 없어요.', style: TextStyle(color: cs.onSurfaceVariant))
      else
        LayoutBuilder(builder: (context, box) {
          const gap = 8.0;
          final w = (box.maxWidth - gap * 2) / 3;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (final e in years)
              SizedBox(
                width: w,
                child: Material(
                  key: ValueKey('year-${e.year}'),
                  color: pickedYear == e.year ? cs.primary : Theme.of(context).cardTheme.color,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12), side: BorderSide(color: pickedYear == e.year ? cs.primary : cs.outlineVariant)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => pickYear(e.year),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                      child: Column(children: [
                        Text('${e.year}', style: TextStyle(fontWeight: FontWeight.w700, color: pickedYear == e.year ? cs.onPrimary : cs.onSurface)),
                        Text('${fmtInt(e.n)}장', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: pickedYear == e.year ? cs.onPrimary : cs.onSurfaceVariant)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]);
        }),
      const SizedBox(height: 20),
      Text('직접 고르기', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface)),
      const SizedBox(height: 4),
      monthPick('시작', y1, m1, (y, m) {
        setState(() { y1 = y; m1 = m; y2 ??= y; m2 ??= m; });
        resolve();
      }),
      monthPick('끝', y2, m2, (y, m) {
        setState(() { y2 = y; m2 = m; y1 ??= y; m1 ??= m; });
        resolve();
      }),
    ]);
  }

  Widget ageTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (loaded && born.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text('인물에 생년을 넣으면 나이로 거를 수 있어요.', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, height: 1.5)),
      );
    }
    final r = result;
    final lo = a == null ? null : (b == null || a! < b! ? a! : b!), hi = a == null ? null : (b == null || a! > b! ? a! : b!);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('누구 나이로?', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface)),
      const SizedBox(height: 8),
      SizedBox(
        height: MediaQuery.textScalerOf(context).scale(12) + 60,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final p in born)
            Semantics(
              key: ValueKey('age-who-${p['id']}'),
              button: true,
              selected: who == p['id'],
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  setState(() => who = p['id'] as int);
                  resolve();
                },
                child: SizedBox(
                  width: 60,
                  child: Column(children: [
                    const SizedBox(height: 4),
                    DecoratedBox(
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, border: Border.all(color: who == p['id'] ? cs.primary : Colors.transparent, width: 2.5)),
                      child: FaceAvatar(face: p['face'] as int?, label: p['name'] as String, size: 40),
                    ),
                    const SizedBox(height: 4),
                    Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: who == p['id'] ? FontWeight.w700 : null)),
                  ]),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      Text('몇 살 때?', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface)),
      const SizedBox(height: 2),
      Text('두 개를 누르면 그 사이 전부', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (var i = 0; i < periodAges.length; i++)
          ChoiceChip(
            key: ValueKey('age-${periodAges[i].label}'),
            label: Text(periodAges[i].label),
            selected: lo != null && i >= lo && i <= hi!,
            onSelected: (_) => pickAge(i),
          ),
      ]),
      const SizedBox(height: 16),
      if (r != null && r.age != null)
        Text('${r.label} → ${ym(r.from)} ~ ${ym(r.to)}', key: const ValueKey('age-preview'),
            style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary))
      else
        Text(who == null ? '누구 나이인지 골라 주세요.' : '나이를 골라 주세요.', style: TextStyle(color: cs.onSurfaceVariant)),
    ]);
  }
}

/// 홈 인물 칩 줄 맨 앞의 '기간' 칩. 안 골랐으면 테두리 칩 "📅 기간 ▾", 골랐으면 채운 칩 "2023년 ✕"(✕ 터치 40dp)
class PeriodFilterChip extends StatelessWidget {
  const PeriodFilterChip({super.key, required this.pick, required this.onOpen, required this.onClear});
  final PeriodPick? pick;
  final VoidCallback onOpen, onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = pick != null;
    final fg = on ? cs.onPrimary : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        key: const ValueKey('home-period-chip'),
        color: on ? cs.primary : Theme.of(context).cardTheme.color,
        shape: StadiumBorder(side: BorderSide(color: on ? cs.primary : cs.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        // 칩 줄(가로 목록)이 높이를 정해 주므로 누르는 곳이 칩 높이 전체가 되게 늘린다
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 0, on ? 2 : 10, 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.calendar_month, size: 18, color: on ? fg : cs.primary),
                const SizedBox(width: 6),
                Text(on ? pick!.label : '기간', style: TextStyle(fontWeight: FontWeight.w600, color: fg)),
                if (!on) Icon(Icons.expand_more, size: 18, color: cs.onSurfaceVariant),
              ]),
            ),
          ),
          if (on)
            IconButton(
              tooltip: '기간 풀기',
              onPressed: onClear,
              icon: const Icon(Icons.close),
              iconSize: 16,
              color: fg,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            ),
        ]),
      ),
    );
  }
}

/// 검색 결과 '이렇게 이해했어요' 줄 끝의 점선 '+ 기간' 칩(기간이 없을 때만)
class AddPeriodChip extends StatelessWidget {
  const AddPeriodChip({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CustomPaint(
      key: const ValueKey('add-period-chip'),
      foregroundPainter: _DashedStadium(cs.outline),
      child: Material(
        color: Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add, size: 18, color: cs.primary),
                const SizedBox(width: 4),
                Text('기간', style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedStadium extends CustomPainter {
  const _DashedStadium(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect.deflate(0.75), Radius.circular(size.height / 2)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedStadium old) => old.color != color;
}
