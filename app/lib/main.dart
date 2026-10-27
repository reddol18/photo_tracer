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
        home: const Home(),
      );
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
        info = '후보 ${fmtInt(r['candidates'])}개 중 신뢰도 높은 ${list.length}개 · 검색어 처리 ${(r['query_ms'] as num).round()}ms'
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
              final label = it['date'] != null ? fmtDate(it['date'] as int) : (it['received'] != null ? '받은 날 ${fmtDate(it['received'] as int)}' : '날짜 모름');
              final conf = ((it['conf'] as num) * 100).round();
              return GestureDetector(
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
                  // 신뢰도: 검색어와 맞는 사진일 확률(SigLIP). 결과는 높은 순
                  Positioned(
                    right: 0, top: 0,
                    child: Container(
                      color: conf >= 50 ? Colors.green.shade700 : (conf >= 10 ? Colors.orange.shade800 : Colors.black54),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      child: Text('$conf%', style: const TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ),
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

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  List<Map<String, dynamic>>? people;
  final selected = <int>[]; // 길게 눌러 고른 인물(합치기). 처음 고른 인물로 합친다

  Future<void> load({bool recluster = false}) async {
    if (recluster) {
      setState(() => people = null);
      await channel.invokeMethod('recluster');
    }
    final r = await channel.invokeMethod('persons');
    if (mounted) setState(() => people = (r as List).map((e) => Map<String, dynamic>.from(e)).toList());
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> recluster() async {
    final ok = await confirm(context, '처음부터 다시 묶을까요?', '손으로 뺀 사진과 합친 인물이 모두 처음 상태로 돌아갑니다.');
    if (ok) load(recluster: true);
  }

  Future<void> merge() async {
    final ok = await confirm(context, '인물 ${selected.length}명을 합칠까요?', '모두 인물 ${selected.first}(으)로 합칩니다.');
    if (!ok) return;
    await channel.invokeMethod('personMerge', {'ids': selected});
    setState(selected.clear);
    load();
  }

  void toggle(int id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id));

  @override
  Widget build(BuildContext context) {
    final p = people;
    return Column(children: [
      selected.isEmpty
          ? ListTile(
              title: Text('인물', style: Theme.of(context).textTheme.titleLarge),
              subtitle: const Text('같은 사람으로 보이는 얼굴끼리 묶었습니다. 길게 눌러 여러 명을 고르면 합칠 수 있습니다.'),
              trailing: IconButton(icon: const Icon(Icons.refresh), tooltip: '처음부터 다시 묶기', onPressed: recluster),
            )
          : ListTile(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
              title: Text('${selected.length}명 고름'),
              trailing: FilledButton(onPressed: selected.length >= 2 ? merge : null, child: const Text('합치기')),
            ),
      Expanded(
        child: p == null
            ? const Center(child: CircularProgressIndicator())
            : p.isEmpty
                ? const Center(child: Text('아직 묶인 얼굴이 없습니다. 밤 정리가 끝나면 생깁니다.'))
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.8),
                    itemCount: p.length,
                    itemBuilder: (context, i) {
                      final id = (p[i]['id'] as num).toInt();
                      final on = selected.contains(id);
                      return GestureDetector(
                        onTap: () async {
                          if (selected.isNotEmpty) return toggle(id);
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => PersonPage(id: id)));
                          load(); // 빼낸 사진만큼 장 수가 바뀐다
                        },
                        onLongPress: () => toggle(id),
                        child: Column(children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: Stack(fit: StackFit.expand, children: [
                              ClipOval(child: Thumb(p[i]['face'] as int, face: true)),
                              if (on)
                                Container(
                                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black38,
                                      border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3)),
                                  child: Center(child: Text('${selected.indexOf(id) + 1}',
                                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))),
                                ),
                            ]),
                          ),
                          const SizedBox(height: 4),
                          Text('$id번 · ${p[i]['n']}장', style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      );
                    },
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

// ───────────────────────────── 인물 한 명의 사진 (신뢰도, 빼기)

class PersonPage extends StatefulWidget {
  const PersonPage({super.key, required this.id});
  final int id;

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  List<Map<String, dynamic>>? photos; // id, face, sim
  bool lowFirst = false; // 신뢰도 낮은 것부터 (잘못 묶인 사진 찾기)
  final selected = <int>{};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await channel.invokeMethod('personPhotos', {'id': widget.id});
    if (mounted) setState(() => photos = (r as List).map((e) => Map<String, dynamic>.from(e)).toList());
  }

  List<Map<String, dynamic>> get sorted {
    final list = [...photos!];
    if (lowFirst) list.sort((a, b) => (a['sim'] as num).compareTo(b['sim'] as num));
    return list;
  }

  Future<void> remove(List<int> ids) async {
    await channel.invokeMethod('personRemove', {'id': widget.id, 'photos': ids});
    setState(selected.clear);
    await load();
  }

  void toggle(int id) => setState(() => selected.contains(id) ? selected.remove(id) : selected.add(id));

  @override
  Widget build(BuildContext context) {
    final list = photos == null ? null : sorted;
    return Scaffold(
      appBar: selected.isEmpty
          ? AppBar(
              title: Text('인물 ${widget.id} · ${photos?.length ?? '…'}장'),
              actions: [
                TextButton.icon(
                  onPressed: () => setState(() => lowFirst = !lowFirst),
                  icon: const Icon(Icons.sort),
                  label: Text(lowFirst ? '신뢰도 낮은 순' : '날짜순'),
                ),
              ],
            )
          : AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
              title: Text('${selected.length}장 고름'),
              actions: [
                TextButton(onPressed: () => remove(selected.toList()), child: const Text('이 인물에서 빼기')),
              ],
            ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final it = list[i];
                final id = it['id'] as int;
                final sim = it['sim'] as num;
                return GestureDetector(
                  onTap: () async {
                    if (selected.isNotEmpty) return toggle(id);
                    final out = await showPhoto(context, id, person: widget.id, sim: sim.toDouble());
                    if (out == true) remove([id]);
                  },
                  onLongPress: () => toggle(id),
                  child: Stack(fit: StackFit.expand, children: [
                    Thumb(id),
                    Positioned(right: 0, top: 0, child: SimBadge(sim.toDouble())),
                    if (selected.contains(id))
                      Container(
                        color: Colors.black45,
                        child: const Icon(Icons.check_circle, color: Colors.white, size: 32),
                      ),
                  ]),
                );
              },
            ),
    );
  }
}

/// 얼굴 신뢰도: 묶음 중심과 닮은 정도(코사인). 묶일 때 기준이 0.55라 그 아래는 빨강
class SimBadge extends StatelessWidget {
  const SimBadge(this.sim, {super.key});
  final double sim;

  @override
  Widget build(BuildContext context) => Container(
        color: sim >= 0.65 ? Colors.green.shade700 : (sim >= 0.55 ? Colors.orange.shade800 : Colors.red.shade700),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text('${(sim * 100).round()}', style: const TextStyle(color: Colors.white, fontSize: 11)),
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

/// 사진 크게 보기. person을 주면 그 인물로 묶인 얼굴은 초록 상자, 다른 얼굴은 얇은 흰 상자로 표시하고
/// '이 인물에서 빼기' 버튼을 단다(누르면 true를 돌려준다).
Future<bool?> showPhoto(BuildContext context, int id, {int? person, double? sim}) => showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias, // 둥근 모서리 밖으로 사진이 튀어나오지 않게
        child: FutureBuilder(
          future: channel.invokeMethod('photoInfo', {'id': id}),
          builder: (context, snap) {
            final m = snap.data == null ? null : Map<String, dynamic>.from(snap.data as Map);
            final faces = m == null ? <Map<String, dynamic>>[] : (m['faces'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
            String info = '';
            if (m != null) {
              final src = m['date_source'];
              final taken = m['taken'] == null ? '찍은 날 모름' : '찍은 날 ${fmtDate(m['taken'] as int, time: true)}${src == '이름' ? ' (파일 이름으로 추정)' : ''}';
              final got = m['received'] == null ? '' : ' · 받은 날 ${fmtDate(m['received'] as int)}';
              info = '$taken$got · 날짜 근거: $src';
            }
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Flexible(child: FacePhoto(id, faces: faces, person: person)),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Text(m == null ? ' ' : info, style: Theme.of(context).textTheme.bodySmall),
              ),
              if (person != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(children: [
                    if (sim != null) ...[SimBadge(sim), const SizedBox(width: 6)],
                    Expanded(child: Text(
                        faces.where((f) => f['person'] == person).length > 1 ? '초록 상자 얼굴들을 이 인물로 묶음' : '초록 상자 얼굴을 이 인물로 묶음',
                        style: Theme.of(context).textTheme.bodySmall)),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('이 인물에서 빼기')),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );

/// 사진 위에 얼굴 상자. 얼굴 위치는 사진 대비 0~1이라, 디코드한 사진 비율대로 자리를 잡고 그 위에 그린다
class FacePhoto extends StatelessWidget {
  const FacePhoto(this.id, {super.key, this.faces = const [], this.person});
  final int id;
  final List<Map<String, dynamic>> faces;
  final int? person;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: Thumb.bytes(id, 1024),
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
          return FutureBuilder<ui.Image>(
            future: decodeImageFromList(data),
            builder: (context, img) {
              if (img.data == null) return const SizedBox(height: 240);
              return AspectRatio(
                aspectRatio: img.data!.width / img.data!.height,
                child: Stack(fit: StackFit.expand, children: [
                  Image.memory(data, fit: BoxFit.fill, gaplessPlayback: true),
                  if (person != null) CustomPaint(painter: _FaceBoxes(faces, person!, Theme.of(context).colorScheme.primary)),
                ]),
              );
            },
          );
        },
      );
}

class _FaceBoxes extends CustomPainter {
  _FaceBoxes(this.faces, this.person, this.color);
  final List<Map<String, dynamic>> faces;
  final int person;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in faces) {
      final mine = f['person'] == person;
      final r = Rect.fromLTWH((f['x'] as num) * size.width, (f['y'] as num) * size.height,
          (f['w'] as num) * size.width, (f['h'] as num) * size.height);
      canvas.drawRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = mine ? 3 : 1.5
        ..color = mine ? Colors.greenAccent : Colors.white70);
    }
  }

  @override
  bool shouldRepaint(_FaceBoxes old) => old.faces != faces || old.person != person;
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
