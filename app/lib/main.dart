import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Photo Tracer 미니 앱: 설치 → 밤에 충전하며 사진 정리 → 아침에 검색·인물.
/// 화면은 이 파일 하나, 분석은 모두 Kotlin(android/app/src/main/kotlin)에서 한다.
const channel = MethodChannel('app');

void main() => runApp(const PhotoTracerApp());

class PhotoTracerApp extends StatelessWidget {
  const PhotoTracerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Photo Tracer',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        scrollBehavior: const _FastScroll(),
        home: const Home(),
      );
}

/// 스크롤되는 곳마다 전체 중 어디쯤인지 보여 주는 반투명 막대. 막대를 끌면 사진 그리드처럼 긴 목록도 빨리 넘긴다.
/// 안드로이드 기본은 막대가 없어서(데스크톱만 그린다) 모든 스크롤에 직접 단다. 한 줄 입력칸은 Flutter가 알아서 뺀다
class _FastScroll extends MaterialScrollBehavior {
  const _FastScroll();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    final vertical = axisDirectionToAxis(details.direction) == Axis.vertical;
    return RawScrollbar(
      controller: details.controller,
      thumbVisibility: true,
      interactive: true, // 손가락으로 막대를 끌어 스크롤 (터치는 막대 둘레 48px까지 잡힌다)
      thickness: vertical ? 8 : 5,
      radius: const Radius.circular(4),
      minThumbLength: 48, // 사진이 수천 장이어도 잡을 수 있게
      thumbColor: Theme.of(context).colorScheme.onSurface.withAlpha(90),
      child: child,
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: IndexedStack(index: tab, children: const [SetupPage(), SearchPage(), PeoplePage(), RunsPage()]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.nightlight_outlined), label: '정리'),
            NavigationDestination(icon: Icon(Icons.search), label: '검색'),
            NavigationDestination(icon: Icon(Icons.face_outlined), label: '인물'),
            NavigationDestination(icon: Icon(Icons.list_alt), label: '기록'),
          ],
        ),
      );
}

String fmtDate(int? ms, {bool time = false}) {
  if (ms == null) return '날짜 모름';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  final day = '${d.year}.${two(d.month)}.${two(d.day)}';
  return time ? '$day ${two(d.hour)}:${two(d.minute)}' : day;
}

String fmtInt(num v) => v.toInt().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

// ───────────────────────────── 정리 (설치 직후 안내 + 진행 상황)

/// 제조사가 배터리 최적화 예외(3번)와 따로 앱을 재우거나 막는 설정. 기본 안드로이드(픽셀 등)는 3번이면 충분해 안내하지 않는다
({String title, String body, String button})? vendorGuide(String manufacturer) {
  final m = manufacturer.toLowerCase();
  if (RegExp('xiaomi|redmi|poco').hasMatch(m)) {
    return (
      title: '샤오미·레드미 폰: 자동 시작',
      body: '목록에서 Photo Tracer의 "자동 시작"을 켜 주세요. 끄면 앱이 꺼진 뒤(재부팅 등) 밤 정리가 다시 깨어나지 못할 수 있습니다.',
      button: '자동 시작',
    );
  }
  if (m == 'samsung') {
    return (
      title: '삼성 갤럭시: 절전 예외 앱',
      body: '배터리 → 백그라운드 사용 제한 → "절전 예외 앱"에 Photo Tracer를 넣어 주세요. '
          '며칠 앱을 열지 않으면 "잠자기 앱"으로 옮겨져 밤 정리가 멈출 수 있습니다.',
      button: '설정 열기',
    );
  }
  if (RegExp('oppo|realme|oneplus|vivo|iqoo|huawei|honor|meizu|asus').hasMatch(m)) {
    return (
      title: '이 폰: 백그라운드 실행 허용',
      body: '앱 정보에서 배터리를 "제한 없음"으로 바꾸고, "자동 시작"이나 "백그라운드 실행 허용"이 있으면 켜 주세요.',
      button: '앱 정보',
    );
  }
  return null;
}

class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> with WidgetsBindingObserver {
  Map<String, dynamic>? s;
  Timer? timer;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh(scan: true);
    timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    super.dispose();
  }

  // 설정 화면에서 돌아오면 권한 상태를 다시 읽는다
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh(scan: true);
  }

  // 스캔은 백그라운드 작업(알림이 뜨는 FGS)으로 맡기고, 화면은 진행만 읽어 온다
  Future<void> refresh({bool scan = false}) async {
    try {
      if (scan) await channel.invokeMethod('scan');
      final st = Map<String, dynamic>.from(await channel.invokeMethod('status'));
      if (mounted) setState(() { s = st; error = null; });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  String scanText(Map<String, dynamic> st) {
    if (st['scan_phase'] == '구간') return '시간 구간을 나누는 중…';
    final total = st['scan_total'] as int;
    if (total == 0) return '갤러리를 여는 중…';
    return '갤러리를 읽는 중… ${fmtInt(st['scan_done'])} / ${fmtInt(total)}장 (다른 앱으로 가도 계속됩니다)';
  }

  Widget step(bool done, String title, String body, String button, VoidCallback onTap) => Card(
        child: ListTile(
          leading: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? Colors.teal : null),
          title: Text(title),
          subtitle: Text(body),
          trailing: done ? null : FilledButton.tonal(onPressed: onTap, child: Text(button)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final st = s;
    if (st == null) return Center(child: error == null ? const CircularProgressIndicator() : Text(error!));
    final photos = st['photos'] as int;
    final facesDone = st['faces_done'] as int;
    final vecNeeded = st['vec_needed'] as int;
    final vecDone = st['vec_done'] as int;
    final total = photos + vecNeeded;
    final done = facesDone + vecDone;
    final vendor = vendorGuide('${st['manufacturer']}');
    return RefreshIndicator(
      onRefresh: () => refresh(scan: true),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('사진 정리', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        const Text('사진은 이 폰 밖으로 나가지 않습니다. 정리는 폰 안에서만 합니다.'),
        const SizedBox(height: 16),
        step(st['photos_permission'] == true, '1. 사진 접근', '갤러리 사진을 읽어 사람·장면·날짜를 정리합니다.', '허용', () async {
          await channel.invokeMethod('requestPermissions');
          refresh(scan: true);
        }),
        step(st['notifications'] == true, '2. 알림', '밤에 정리하는 동안 진행률을 알림으로 보여 줍니다.', '허용', () async {
          await channel.invokeMethod('requestPermissions');
          refresh();
        }),
        step(st['battery_exempt'] == true, '3. 배터리 최적화 예외',
            '밤새 정리하려면 시스템이 이 앱을 멈추지 않게 해야 합니다.', '설정', () => channel.invokeMethod('openBatterySettings')),
        if (vendor != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(vendor.title),
              subtitle: Text(vendor.body),
              trailing: FilledButton.tonal(onPressed: () => channel.invokeMethod('openVendorSettings'), child: Text(vendor.button)),
            ),
          ),
        const SizedBox(height: 16),
        // 꺼 두면 시스템 자동 시작이 켜져 있어도 밤 작업이 깨어나지 않는다. 지금 시작은 그대로 쓸 수 있다
        SwitchListTile(
          title: const Text('밤에 자동 정리'),
          subtitle: const Text('충전 중이고 화면이 꺼져 있을 때 새 사진을 정리합니다'),
          value: st['night_on'] == true,
          onChanged: (on) async {
            await channel.invokeMethod('setNight', {'on': on});
            refresh();
          },
        ),
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(st['running'] == true
                      ? '지금 정리하고 있습니다'
                      : total > 0 && done >= total
                          ? '정리가 끝났습니다'
                          : st['night_on'] == true ? '오늘 밤 충전기에 꽂아 두세요' : '밤 정리가 꺼져 있습니다',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(st['scan_phase'] != null
                  ? scanText(st)
                  : st['night_on'] == true
                      ? '충전 중이고 화면이 꺼져 있을 때 조금씩 정리합니다. 처음에는 며칠 밤 걸릴 수 있습니다.'
                      : '위 스위치를 켜거나 "지금 시작"을 누르면 정리합니다.'),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                  value: st['scan_phase'] != null
                      ? ((st['scan_total'] as int) == 0 ? null : (st['scan_done'] as int) / (st['scan_total'] as int))
                      : (total == 0 ? 0 : done / total)),
              const SizedBox(height: 8),
              Text('사진 ${fmtInt(photos)}장 · 시간 구간 ${fmtInt(st['segments'])}개'),
              Text('얼굴 확인 ${fmtInt(facesDone)} / ${fmtInt(photos)}장 · 찾은 얼굴 ${fmtInt(st['faces'])}개 · 인물 ${st['persons']}명'),
              Text('장면 분석 ${fmtInt(vecDone)} / ${fmtInt(vecNeeded)}장 (구간 대표 사진과 날짜 없는 사진)'),
              if ((st['failed'] as int) > 0) Text('읽지 못한 사진 ${st['failed']}장'),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        // 도는 중이면 멈춤만, 아니면 지금 시작만 (갤러리를 읽는 동안은 둘 다 기다림)
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: st['photos_permission'] == true && st['running'] != true && st['scan_phase'] == null
                  ? () async { await channel.invokeMethod('startNow'); refresh(); }
                  : null,
              child: const Text('지금 시작 (시험용)'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: st['running'] == true ? () async { await channel.invokeMethod('stopNow'); refresh(); } : null,
            child: const Text('멈춤'),
          ),
        ]),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
      ]),
    );
  }
}

// ───────────────────────────── 검색

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final ctrl = TextEditingController();
  List<Map<String, dynamic>> items = [];
  String info = '예: 바다에서 노는 아이, 생일 케이크, 눈 오는 날';
  bool busy = false;

  Future<void> run(String q) async {
    if (q.trim().isEmpty) return;
    setState(() { busy = true; info = '찾는 중… (처음 한 번은 검색 모델을 여느라 몇 초 걸립니다)'; });
    try {
      final r = Map<String, dynamic>.from(await channel.invokeMethod('search', {'q': q}));
      final list = (r['items'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
      setState(() {
        items = list;
        info = '후보 ${fmtInt(r['candidates'])}개 중 잘 맞는 순 ${list.length}개 · 검색어 처리 ${(r['query_ms'] as num).round()}ms'
            ' · 전체 ${(r['total_ms'] as num).round()}ms';
      });
    } catch (e) {
      setState(() => info = '$e');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: TextField(
            controller: ctrl,
            textInputAction: TextInputAction.search,
            onSubmitted: run,
            decoration: InputDecoration(
              hintText: '어떤 사진을 찾을까요?',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: busy ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)) : null,
            ),
          ),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(info, style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 8),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final it = items[i];
              final guessed = it['date_source'] == '이름';
              final label = it['date'] != null ? fmtDate(it['date'] as int) : (it['received'] != null ? '받은 날 ${fmtDate(it['received'] as int)}' : '날짜 모름');              return GestureDetector(
                onTap: () {
                  if (it['kind'] == 'segment') {
                    Navigator.push(context, MaterialPageRoute(
                        builder: (_) => PhotosPage(title: '${fmtDate(it['date'] as int)} · ${it['n']}장',
                            load: () => channel.invokeMethod('segmentPhotos', {'id': it['id']}))));
                  } else {
                    showPhoto(context, it['cover'] as int);
                  }
                },
                child: Stack(fit: StackFit.expand, children: [
                  Thumb(it['cover'] as int),
                  Positioned(
                    left: 0, right: 0, bottom: 0,
                    child: Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text('$label${guessed ? ' 추정' : ''}${it['kind'] == 'segment' ? ' · ${it['n']}장' : ''}',
                          style: const TextStyle(color: Colors.white, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ]);
}

// ───────────────────────────── 인물
// 등록한 인물: 사용자가 고른 정답 얼굴과 닮은 얼굴을 찾는다(Who.kt). 자동 묶음은 정답 얼굴을 고를 때 참고로만 쓴다.

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  List<Map<String, dynamic>>? people;
  List<Map<String, dynamic>>? clusters;
  final selected = <int>[]; // 길게 눌러 고른 등록 인물(합치기). 처음 고른 인물로 합친다

  Future<void> load({bool recluster = false}) async {
    if (recluster) {
      setState(() => clusters = null);
      await channel.invokeMethod('recluster');
    }
    final p = await channel.invokeMethod('people');
    final c = await channel.invokeMethod('persons');
    if (mounted) {
      setState(() {
        people = (p as List).map((e) => Map<String, dynamic>.from(e)).toList();
        clusters = (c as List).map((e) => Map<String, dynamic>.from(e)).toList();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> merge() async {
    final names = {for (final p in people!) p['id'] as int: personLabel(p)};
    final ok = await confirm(context, '${selected.length}명을 합칠까요?', '정답 얼굴을 모두 "${names[selected.first]}"(으)로 모읍니다.');
    if (!ok) return;
    await channel.invokeMethod('whoMerge', {'ids': selected});
    setState(selected.clear);
    load();
  }

  void toggle(int id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id));

  Widget faceTile(BuildContext context, int? face, String label, {bool on = false, String? mark}) => Column(children: [
        AspectRatio(
          aspectRatio: 1,
          child: Stack(fit: StackFit.expand, children: [
            ClipOval(child: face == null ? Container(color: Colors.black12) : Thumb(face, face: true)),
            if (on)
              Container(
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black38,
                    border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3)),
                child: Center(child: Text(mark ?? '', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
              ),
          ]),
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      ]);

  @override
  Widget build(BuildContext context) {
    final p = people, c = clusters;
    if (p == null || c == null) return const Center(child: CircularProgressIndicator());
    const grid = SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.8);
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: selected.isEmpty
            ? ListTile(
                title: Text('등록한 인물', style: Theme.of(context).textTheme.titleLarge),
                subtitle: Text(p.isEmpty
                    ? '아래 자동 묶음에서 사진을 열고 얼굴을 눌러 "새 인물로 등록"하세요. 정답 얼굴과 닮은 얼굴을 찾아 줍니다.'
                    : '길게 눌러 여러 명을 고르면 합칠 수 있습니다. 해마다 정답 얼굴을 몇 개씩 넣으면 더 잘 찾습니다.'),
              )
            : ListTile(
                leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
                title: Text('${selected.length}명 고름'),
                trailing: FilledButton(onPressed: selected.length >= 2 ? merge : null, child: const Text('합치기')),
              ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: grid,
          delegate: SliverChildBuilderDelegate(childCount: p.length, (context, i) {
            final id = p[i]['id'] as int;
            return GestureDetector(
              onTap: () async {
                if (selected.isNotEmpty) return toggle(id);
                await Navigator.push(context, MaterialPageRoute(builder: (_) => WhoPage(id: id)));
                load();
              },
              onLongPress: () => toggle(id),
              child: faceTile(context, p[i]['face'] as int?, '${personLabel(p[i])} · ${p[i]['n']}장',
                  on: selected.contains(id), mark: '${selected.indexOf(id) + 1}'),
            );
          }),
        ),
      ),
      SliverToBoxAdapter(
        child: ListTile(
          title: Text('자동 묶음 (참고용)', style: Theme.of(context).textTheme.titleMedium),
          subtitle: const Text('비슷한 얼굴끼리 자동으로 묶은 것입니다. 아이들끼리 섞일 수 있어 정답 얼굴을 고를 때만 쓰세요.'),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '처음부터 다시 묶기',
            onPressed: () async {
              if (await confirm(context, '자동 묶음을 다시 만들까요?', '등록한 인물과 정답 얼굴은 그대로 둡니다.')) load(recluster: true);
            },
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverGrid(
          gridDelegate: grid,
          delegate: SliverChildBuilderDelegate(childCount: c.length, (context, i) {
            final id = (c[i]['id'] as num).toInt();
            return GestureDetector(
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(
                    builder: (_) => PhotosPage(title: '자동 묶음 $id · ${c[i]['n']}장',
                        load: () => channel.invokeMethod('personPhotos', {'id': id}).then((r) => (r as List).map((e) => (e as Map)['id']).toList()))));
                load();
              },
              child: faceTile(context, c[i]['face'] as int, '묶음 $id · ${c[i]['n']}장'),
            );
          }),
        ),
      ),
    ]);
  }
}

// ───────────────────────────── 기록 (밤 작업마다 한 줄)

class RunsPage extends StatefulWidget {
  const RunsPage({super.key});

  @override
  State<RunsPage> createState() => _RunsPageState();
}

class _RunsPageState extends State<RunsPage> {
  List<Map<String, dynamic>> runs = [];
  String? exported;

  Future<void> load() async {
    final r = await channel.invokeMethod('runs');
    if (mounted) setState(() => runs = (r as List).map((e) => Map<String, dynamic>.from(e)).toList());
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  String line(Map<String, dynamic> r) {
    String secs(num? ms) => ms == null ? '-' : '${(ms / 1000).toStringAsFixed(1)}초';
    final end = r['end'] as int?;
    final stop = r['stop'] ?? (end == null ? '기록 없이 끊김 (마지막 ${fmtDate(r['last'] as int, time: true)})' : '');
    return '${fmtInt(r['photos'])}장 · 얼굴 ${fmtInt(r['faces'])}개 · 장면 ${fmtInt(r['vectors'])}장\n'
        '장당 얼굴 ${secs(r['face_ms'] as num?)} · 장면 ${secs(r['vec_ms'] as num?)} · 쉼 ${r['rests']}번'
        ' · 최고 ${(r['max_temp'] as num? ?? 0).toStringAsFixed(1)}℃\n'
        '끝: $stop · ${r['note'] ?? ''}';
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('밤 작업 기록', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (runs.isEmpty) const Text('아직 기록이 없습니다.'),
          for (final r in runs)
            Card(
              child: ListTile(
                title: Text('${fmtDate(r['start'] as int, time: true)} → '
                    '${r['end'] != null ? fmtDate(r['end'] as int, time: true) : '?'} · ${r['mode'] == 'night' ? '밤' : '시험'}'),
                subtitle: Text(line(r)),
                isThreeLine: true,
              ),
            ),
          const Divider(height: 32),
          Text('개발용', style: Theme.of(context).textTheme.titleSmall),
          OutlinedButton(
            onPressed: () async {
              setState(() => exported = '만드는 중…');
              try {
                final path = await channel.invokeMethod('exportQueryVectors');
                setState(() => exported = '$path');
              } catch (e) {
                setState(() => exported = '$e');
              }
            },
            child: const Text('검색어 벡터 내보내기 (PC와 비교)'),
          ),
          if (exported != null) SelectableText(exported!),
        ]),
      );
}

// ───────────────────────────── 공용: 사진 목록·썸네일

class PhotosPage extends StatefulWidget {
  const PhotosPage({super.key, required this.title, required this.load});
  final String title;
  final Future<dynamic> Function() load;

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> {
  List<int>? ids;

  @override
  void initState() {
    super.initState();
    widget.load().then((r) => setState(() => ids = (r as List).map((e) => (e as num).toInt()).toList()));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: ids == null
            ? const Center(child: CircularProgressIndicator())
            : GridView.builder(
                padding: const EdgeInsets.all(4),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                itemCount: ids!.length,
                itemBuilder: (context, i) => GestureDetector(onTap: () => showPhoto(context, ids![i]), child: Thumb(ids![i])),
              ),
      );
}

// ───────────────────────────── 등록한 인물 한 명 (정답·찾음·확인 필요)

class WhoPage extends StatefulWidget {
  const WhoPage({super.key, required this.id});
  final int id;

  @override
  State<WhoPage> createState() => _WhoPageState();
}

class _WhoPageState extends State<WhoPage> {
  static const kinds = {'all': '전체', 'ref': '정답', 'found': '찾음', 'maybe': '확인 필요'};
  List<Map<String, dynamic>>? photos; // id, face, sim, kind
  Map<String, dynamic> person = {'name': ''}; // name, relation, birth_year
  String get name => person['name'] as String;
  String kind = 'all';
  int? year; // 찍은 해로 거르기. null: 모든 해, 0: 찍은 날 모름
  bool lowFirst = false; // 신뢰도 낮은 것부터 (잘못 찾은 사진 먼저)

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
    final p = (await channel.invokeMethod('people') as List).map((e) => Map<String, dynamic>.from(e));
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
    } else if (v == 'delete') {
      if (await confirm(context, '"$name"을(를) 지울까요?', '정답 얼굴 표시도 함께 지웁니다. 사진은 지우지 않습니다.')) {
        await channel.invokeMethod('whoDelete', {'id': widget.id});
        if (mounted) Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = photos == null ? null : shown;
    final all = photos ?? [];
    // 개수는 서로 걸러서: 종류 칩은 고른 해 안에서, 연도 칩은 고른 종류 안에서
    final count = {for (final k in kinds.keys) k: all.where((p) => kindOk(p, k) && yearOk(p, year)).length};
    final byYear = <int, int>{};
    for (final p in all.where((p) => kindOk(p, kind))) {
      byYear.update(yearOf(p), (n) => n + 1, ifAbsent: () => 1);
    }
    if (year != null) byYear.putIfAbsent(year!, () => 0); // 종류를 바꿔 0장이 돼도 고른 칩은 남긴다
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a)); // 최근 해부터, 모름(0)은 맨 뒤
    final birth = person['birth_year'] as int?;
    String yearLabel(int y) => y == 0 ? '찍은 날 모름' : birth != null && y >= birth ? '$y · ${y - birth}살' : '$y';
    return Scaffold(
      appBar: selected.isEmpty
          ? AppBar(
              title: Text('${personLabel(person)}${person['birth_year'] != null ? ' · ${person['birth_year']}년생' : ''}'
                  ' · ${all.length}장'),
              actions: [
                TextButton.icon(
                  onPressed: () => setState(() => lowFirst = !lowFirst),
                  icon: const Icon(Icons.sort),
                  label: Text(lowFirst ? '신뢰도 낮은 순' : '날짜순'),
                ),
                PopupMenuButton<String>(onSelected: menu, itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('이름·관계·생년 고치기')),
                  PopupMenuItem(value: 'delete', child: Text('인물 지우기')),
                ]),
              ],
            )
          : AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
              title: Text('${selected.length}장'),
              actions: [
                TextButton(onPressed: () => act('whoConfirm', selected), child: const Text('정답으로')),
                TextButton(onPressed: () => act('whoReject', selected), child: const Text('이 사람 아님')),
              ],
            ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(children: [
                  for (final k in kinds.keys)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: Text('${kinds[k]} ${count[k]}'), selected: kind == k, onSelected: (_) => setState(() => kind = k)),
                    ),
                ]),
              ),
              // 찍은 해별로: 해마다 정답 얼굴을 몇 개씩 고르기 쉽게. 생년이 있으면 그해 나이도
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Row(children: [
                  for (final y in [null, ...years.where((y) => y != 0), if (byYear.containsKey(0)) 0])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(y == null ? '모든 해 ${byYear.values.fold(0, (a, b) => a + b)}' : '${yearLabel(y)} (${byYear[y]})'),
                        visualDensity: VisualDensity.compact,
                        selected: year == y,
                        onSelected: (_) => setState(() => year = y),
                      ),
                    ),
                ]),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final it = list[i];
                    final id = it['id'] as int;
                    return GestureDetector(
                      onTap: () async {
                        if (selected.isNotEmpty) return toggle(id);
                        await showPhoto(context, id, who: widget.id);
                        load();
                      },
                      onLongPress: () => toggle(id),
                      child: Stack(fit: StackFit.expand, children: [
                        Thumb(id),
                        Positioned(right: 0, top: 0, child: SimBadge((it['sim'] as num).toDouble(), ref: it['kind'] == 'ref')),
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

/// 얼굴 신뢰도: 정답 얼굴과 가장 닮은 정도(코사인). 0.45 이상 + 다른 사람보다 0.10 더 닮아야 '찾음'(Who.kt)
class SimBadge extends StatelessWidget {
  const SimBadge(this.sim, {super.key, this.ref = false});
  final double sim;
  final bool ref;

  @override
  Widget build(BuildContext context) => Container(
        color: ref ? Colors.blue.shade700 : (sim >= 0.55 ? Colors.green.shade700 : (sim >= 0.45 ? Colors.orange.shade800 : Colors.red.shade700)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(ref ? '정답' : '${(sim * 100).round()}', style: const TextStyle(color: Colors.white, fontSize: 11)),
      );
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('확인')),
        ],
      ),
    ) ??
    false;

/// 인물 정보: 이름(또는 호칭, 필수)·관계·생년. 돌려주는 맵은 채널에 그대로 넘긴다
Future<Map<String, dynamic>?> askPerson(BuildContext context, String title, [Map<String, dynamic>? cur]) {
  final name = TextEditingController(text: cur?['name'] as String? ?? '');
  final relation = TextEditingController(text: cur?['relation'] as String? ?? '');
  final birth = TextEditingController(text: cur?['birth_year']?.toString() ?? '');
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: '이름 또는 호칭', hintText: '예: 지우, 엄마')),
        TextField(controller: relation, decoration: const InputDecoration(labelText: '관계 (선택)', hintText: '예: 딸, 아내, 조카')),
        TextField(controller: birth, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '태어난 해 (선택)', hintText: '예: 2022 — 사진마다 그때 나이를 보여 줍니다')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty) return;
            final y = int.tryParse(birth.text.trim());
            Navigator.pop(context, {
              'name': name.text.trim(),
              'relation': relation.text.trim().isEmpty ? null : relation.text.trim(),
              'birth_year': y != null && y > 1900 && y <= DateTime.now().year ? y : null,
            });
          },
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

/// 화면에 쓸 인물 이름: "이름(관계)" — 이름과 관계가 같으면 하나만
String personLabel(Map<String, dynamic> p) {
  final r = p['relation'] as String?;
  return r == null || r == p['name'] ? p['name'] as String : '${p['name']}($r)';
}

/// 사진 크게 보기. 얼굴마다 상자를 그리고 등록한 인물이면 이름을 단다. 얼굴을 누르면
/// 새 인물로 등록 / ○○의 정답으로 / ○○ 아님 을 고를 수 있다. who를 주면 그 인물 얼굴을 초록 상자로 강조한다.
Future<void> showPhoto(BuildContext context, int id, {int? who}) => showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias, // 둥근 모서리 밖으로 사진이 튀어나오지 않게
        child: _PhotoView(id: id, who: who),
      ),
    );

class _PhotoView extends StatefulWidget {
  const _PhotoView({required this.id, this.who});
  final int id;
  final int? who;

  @override
  State<_PhotoView> createState() => _PhotoViewState();
}

class _PhotoViewState extends State<_PhotoView> {
  Map<String, dynamic>? info;
  List<Map<String, dynamic>> people = [];
  int? year; // 찍은 해 (그때 나이 계산용)
  Map<int, String> names = {}; // 고르기 창용 이름
  Map<int, String> labels = {}; // 얼굴 상자 위: 이름 + 그때 나이(생년과 찍은 해로)

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final m = Map<String, dynamic>.from(await channel.invokeMethod('photoInfo', {'id': widget.id}) as Map);
    final p = (await channel.invokeMethod('people') as List).map((e) => Map<String, dynamic>.from(e)).toList();
    final year = m['taken'] == null ? null : DateTime.fromMillisecondsSinceEpoch(m['taken'] as int).year;
    String label(Map<String, dynamic> e) {
      final b = e['birth_year'] as int?;
      return year == null || b == null || year < b ? e['name'] as String : '${e['name']} 약 ${year - b}살';
    }
    if (mounted) {
      setState(() {
        info = m;
        people = p;
        this.year = year;
        names = {for (final e in p) e['id'] as int: personLabel(e)};
        labels = {for (final e in p) e['id'] as int: label(e)};
      });
    }
  }

  Future<void> onFace(Map<String, dynamic> f) async {
    final faceId = f['id'] as int;
    final cur = (f['who'] ?? f['maybe']) as int?;
    // '아님'은 이 얼굴에 붙은 인물, 그리고 지금 보고 있는 인물 페이지의 인물
    final no = {?cur, ?widget.who}.where(names.containsKey).toList();
    // 붙은 인물을 맨 앞에. 인물이 많아도 옆으로 넘기며 얼굴로 고른다
    final list = [...people.where((e) => e['id'] == cur), ...people.where((e) => e['id'] != cur)];
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        final t = Theme.of(context).textTheme;
        Widget card({required Widget face, required String name, String? sub, String? age, bool on = false, required String value}) => InkWell(
              onTap: () => Navigator.pop(context, value),
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 92,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(children: [
                    Container(
                      width: 72, height: 72,
                      decoration: on ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3)) : null,
                      child: ClipOval(child: face),
                    ),
                    const SizedBox(height: 4),
                    Text(name, style: t.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(sub ?? '', style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(age ?? '', style: t.bodySmall, maxLines: 1),
                  ]),
                ),
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (no.isNotEmpty)
                Wrap(spacing: 8, children: [
                  for (final p in no)
                    ActionChip(
                      avatar: const Icon(Icons.block, size: 18),
                      label: Text('"${names[p]}" 아님'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(context, 'no:$p'),
                    ),
                ]),
              Padding(padding: const EdgeInsets.fromLTRB(4, 12, 4, 4), child: Text('이 얼굴은 누구인가요? (정답 얼굴로 등록)', style: t.titleSmall)),
              SizedBox(
                height: 148,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  card(face: Container(color: Colors.black12, child: const Icon(Icons.person_add, size: 32)), name: '새 인물', value: 'new'),
                  for (final p in list)
                    card(
                      face: p['face'] == null ? Container(color: Colors.black12) : Thumb(p['face'] as int, face: true),
                      name: p['name'] as String,
                      sub: p['relation'] as String?,
                      age: switch ((year, p['birth_year'] as int?)) {
                        (final y?, final b?) when y >= b => '약 ${y - b}살',
                        (_, final b?) => '$b년생',
                        _ => null,
                      },
                      on: p['id'] == cur,
                      value: 'ok:${p['id']}',
                    ),
                ]),
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
    } else {
      final [op, person] = choice.split(':');
      await channel.invokeMethod('whoMark', {'id': int.parse(person), 'faces': [faceId], 'ok': op == 'ok'});
    }
    load();
  }

  @override
  Widget build(BuildContext context) {
    final m = info;
    final faces = m == null ? <Map<String, dynamic>>[] : (m['faces'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
    String text = ' ';
    if (m != null) {
      final src = m['date_source'];
      final taken = m['taken'] == null ? '찍은 날 모름' : '찍은 날 ${fmtDate(m['taken'] as int, time: true)}${src == '이름' ? ' (파일 이름으로 추정)' : ''}';
      final got = m['received'] == null ? '' : ' · 받은 날 ${fmtDate(m['received'] as int)}';
      text = '$taken$got · 날짜 근거: $src';
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Flexible(child: FacePhoto(widget.id, faces: faces, names: labels, who: widget.who, onFace: onFace)),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      ),
      if (faces.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text('얼굴을 누르면 정답으로 지정하거나 "아님"으로 뺄 수 있습니다.', style: Theme.of(context).textTheme.bodySmall),
        ),
    ]);
  }
}

/// 사진 위에 얼굴 상자. 얼굴 위치는 사진 대비 0~1이라, 디코드한 사진 비율대로 자리를 잡고 그 위에 그린다
class FacePhoto extends StatefulWidget {
  const FacePhoto(this.id, {super.key, this.faces = const [], this.names = const {}, this.who, this.onFace});
  final int id;
  final List<Map<String, dynamic>> faces;
  final Map<int, String> names;
  final int? who;
  final void Function(Map<String, dynamic> face)? onFace;

  @override
  State<FacePhoto> createState() => _FacePhotoState();
}

class _FacePhotoState extends State<FacePhoto> {
  late final Future<(Uint8List, ui.Image)?> image = _load();

  Future<(Uint8List, ui.Image)?> _load() async {
    final data = await Thumb.bytes(widget.id, 1024);
    return data == null ? null : (data, await decodeImageFromList(data));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: image,
        builder: (context, snap) {
          final r = snap.data;
          if (r == null) return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
          final (data, img) = r;
          return AspectRatio(
            aspectRatio: img.width / img.height,
            child: LayoutBuilder(
              builder: (context, box) => GestureDetector(
                onTapUp: (d) {
                  final x = d.localPosition.dx / box.maxWidth, y = d.localPosition.dy / box.maxHeight;
                  // 상자 안을 누른 얼굴 중 가장 작은 것 (상자가 겹칠 때)
                  final hit = widget.faces.where((f) {
                    final fx = (f['x'] as num).toDouble(), fy = (f['y'] as num).toDouble();
                    final fw = (f['w'] as num).toDouble(), fh = (f['h'] as num).toDouble();
                    return x >= fx - 0.02 && x <= fx + fw + 0.02 && y >= fy - 0.02 && y <= fy + fh + 0.02;
                  }).toList()
                    ..sort((a, b) => ((a['w'] as num) * (a['h'] as num)).compareTo((b['w'] as num) * (b['h'] as num)));
                  if (hit.isNotEmpty) widget.onFace?.call(hit.first);
                },
                child: Stack(fit: StackFit.expand, children: [
                  Image.memory(data, fit: BoxFit.fill, gaplessPlayback: true),
                  CustomPaint(painter: _FaceBoxes(widget.faces, widget.names, widget.who)),
                ]),
              ),
            ),
          );
        },
      );
}

class _FaceBoxes extends CustomPainter {
  _FaceBoxes(this.faces, this.names, this.who);
  final List<Map<String, dynamic>> faces;
  final Map<int, String> names;
  final int? who;

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in faces) {
      final person = f['who'] as int?;
      final maybe = f['maybe'] as int?;
      final mine = who != null && person == who;
      final color = mine ? Colors.greenAccent : (person != null ? Colors.lightBlueAccent : (maybe != null ? Colors.orangeAccent : Colors.white70));
      final r = Rect.fromLTWH((f['x'] as num) * size.width, (f['y'] as num) * size.height,
          (f['w'] as num) * size.width, (f['h'] as num) * size.height);
      canvas.drawRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = mine ? 3 : 1.5
        ..color = color);
      final id = person ?? maybe;
      if (id == null || names[id] == null) continue;
      final sim = f['sim'] as num?;
      final label = '${names[id]}${maybe != null ? '?' : ''}${sim != null && sim < 1 ? ' ${(sim * 100).round()}' : ''}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      // 사진 밖으로 글자가 잘리지 않게 오른쪽 끝에서는 왼쪽으로 민다
      final at = Offset(r.left.clamp(0, (size.width - tp.width - 4).clamp(0, size.width)), (r.top - tp.height - 2).clamp(0, size.height - tp.height));
      canvas.drawRect(Rect.fromLTWH(at.dx, at.dy, tp.width + 4, tp.height), Paint()..color = color);
      tp.paint(canvas, at + const Offset(2, 0));
    }
  }

  @override
  bool shouldRepaint(_FaceBoxes old) => old.faces != faces || old.names != names || old.who != who;
}

/// 썸네일은 Kotlin이 MediaStore에서 만들어 JPEG로 준다. 최근 것만 메모리에 둔다.
class Thumb extends StatelessWidget {
  const Thumb(this.id, {super.key, this.size = 256, this.face = false, this.fit = BoxFit.cover});
  final int id;
  final int size;
  final bool face;
  final BoxFit fit;

  static final _cache = <String, Future<Uint8List?>>{};

  static Future<Uint8List?> bytes(int id, int size, {bool face = false}) {
    final key = '$face/$id/$size';
    final hit = _cache.remove(key);
    final f = hit ?? (face
        ? channel.invokeMethod<Uint8List>('faceThumb', {'id': id})
        : channel.invokeMethod<Uint8List>('thumb', {'id': id, 'size': size}));
    _cache[key] = f; // 맨 뒤로 = 최근
    if (_cache.length > 400) _cache.remove(_cache.keys.first);
    return f;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: bytes(id, size, face: face),
        builder: (context, snap) => snap.data == null
            ? Container(color: Colors.black12)
            : Image.memory(snap.data!, fit: fit, gaplessPlayback: true),
      );
}
