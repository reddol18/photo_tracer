part of '../main.dart';

// ───────────────────────────── 화면 설정: 대표 색 · 화면 모드

/// 사용자가 고른 대표 색과 화면 모드. 설정에서 바꾸면 앱 전체가 다시 그려진다
class Look {
  const Look(this.accentIndex, this.mode);
  final int accentIndex;
  final ThemeMode mode;
  Color get accent => accents[accentIndex].$1;

  /// 고를 수 있는 대표 색 — 흰 글자를 올려도 읽히는 진하기(대비 4.5:1 이상)
  static const accents = <(Color, String)>[
    (Color(0xFF2563EB), '파랑'),
    (Color(0xFF0F766E), '청록'),
    (Color(0xFFC2410C), '주황'),
    (Color(0xFF6D28D9), '보라'),
    (Color(0xFFBE185D), '분홍'),
    (Color(0xFF334155), '먹색'),
  ];
  static const modes = {'system': ThemeMode.system, 'light': ThemeMode.light, 'dark': ThemeMode.dark};

  static final current = ValueNotifier(const Look(0, ThemeMode.system));

  static Future<void> load() async {
    try {
      final a = int.tryParse(await pref('accent') ?? '') ?? 0;
      final m = modes[await pref('mode')] ?? ThemeMode.system;
      current.value = Look(a.clamp(0, accents.length - 1), m);
    } catch (_) {} // 채널이 아직 없으면(테스트) 기본값
  }

  static Future<void> set({int? accent, ThemeMode? mode}) async {
    final v = Look(accent ?? current.value.accentIndex, mode ?? current.value.mode);
    current.value = v;
    await setPref('accent', '${v.accentIndex}');
    await setPref('mode', modes.entries.firstWhere((e) => e.value == v.mode).key);
  }
}

/// 흰(어두운) 바탕에 대표 색 하나만 쓰는 깔끔한 테마. 카드는 그림자 없이 옅은 테두리
ThemeData buildTheme(Color accent, Brightness b) {
  final dark = b == Brightness.dark;
  var cs = ColorScheme.fromSeed(seedColor: accent, brightness: b);
  if (!dark) cs = cs.copyWith(primary: accent, onPrimary: Colors.white);
  final bg = dark ? const Color(0xFF111214) : const Color(0xFFF7F8FA);
  final card = dark ? const Color(0xFF1C1D20) : Colors.white;
  final line = dark ? const Color(0xFF2C2D31) : const Color(0xFFEEF0F3);
  final base = ThemeData(useMaterial3: true, colorScheme: cs, brightness: b);
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    dividerColor: line,
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: card,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: line)),
    ),
    appBarTheme: AppBarTheme(backgroundColor: bg, surfaceTintColor: Colors.transparent, scrolledUnderElevation: 0),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: cs.primary.withValues(alpha: 0.14),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? cs.primary : cs.onSurfaceVariant)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w400,
          color: s.contains(WidgetState.selected) ? cs.primary : cs.onSurfaceVariant)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    ),
    chipTheme: base.chipTheme.copyWith(shape: const StadiumBorder(), side: BorderSide(color: line)),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: card, surfaceTintColor: Colors.transparent, showDragHandle: true),
    dialogTheme: DialogThemeData(backgroundColor: card, surfaceTintColor: Colors.transparent),
  );
}

/// 화면 설정 한 줄(문자열). Kotlin SharedPreferences "ui"에 둔다
Future<String?> pref(String key) => channel.invokeMethod<String>('pref', {'key': key});
Future<void> setPref(String key, String? value) => channel.invokeMethod('setPref', {'key': key, 'value': value});

// ───────────────────────────── 정리 상태: 탭 어디서나 같은 값을 본다

/// 지금 정리 상태(Kotlin status). 앱이 떠 있는 동안 3초마다 읽는다
class Status extends ChangeNotifier {
  Status._();
  static final i = Status._();

  Map<String, dynamic>? s;
  List<Map<String, dynamic>> runs = [];
  String? error;
  Timer? _timer;
  int _tick = 0;

  void start() {
    refresh(scan: true);
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  /// 테스트에서 화면을 닫을 때
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  // 스캔은 백그라운드 작업(알림이 뜨는 FGS)으로 맡기고, 화면은 진행만 읽어 온다
  Future<void> refresh({bool scan = false}) async {
    try {
      if (scan) await channel.invokeMethod('scan');
      s = Map<String, dynamic>.from(await channel.invokeMethod('status'));
      if (scan || _tick++ % 20 == 0) {
        runs = ((await channel.invokeMethod('runs')) as List).map((e) => Map<String, dynamic>.from(e)).toList();
      }
      error = null;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  int _n(String k) => (s?[k] as num?)?.toInt() ?? 0;
  bool get ready => s != null;
  bool get permission => s?['photos_permission'] == true;
  bool get batteryOk => s?['battery_exempt'] == true;
  bool get running => s?['running'] == true;
  bool get nightOn => s?['night_on'] == true;
  bool get scanning => s?['scan_phase'] != null;
  String? get restWhy => s?['rest_why'] as String?;
  int get restLeftMin => _n('rest_left') ~/ 60 + 1;
  int get photos => _n('photos');
  int get segments => _n('segments');
  bool get _reface => _n('reface_done') < _n('reface_needed');

  /// 해야 할 일 전체(얼굴 확인 + 장면 분석 + 얼굴 다시 분석)와 끝낸 일
  int get total => photos - _n('failed') + _n('vec_needed') + (_reface ? _n('reface_needed') : 0);
  int get done => _n('faces_done') + _n('vec_done') + (_reface ? _n('reface_done') : 0);
  double get progress => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);
  bool get allDone => ready && total > 0 && done >= total && !scanning;

  /// 아직 아무것도 정리하지 않음(첫날)
  bool get untouched => ready && _n('faces_done') == 0 && _n('vec_done') == 0;

  /// 지난 밤 작업들로 본 하룻밤 처리량(사진+장면). 다 끝까지 돈 밤 작업이 없으면 null
  int? get perNight {
    final nights = runs.where((r) => r['mode'] == 'night' && r['end'] != null && ((r['photos'] as num? ?? 0) + (r['vectors'] as num? ?? 0)) > 0).take(5).toList();
    if (nights.isEmpty) return null;
    // 같은 날 밤에 여러 번 깨어난 작업은 하루로 묶는다(15분마다 이어 하기 때문)
    final byNight = <int, int>{};
    for (final r in nights) {
      final d = DateTime.fromMillisecondsSinceEpoch((r['start'] as num).toInt()).subtract(const Duration(hours: 12));
      final key = d.year * 10000 + d.month * 100 + d.day;
      byNight.update(key, (v) => v + ((r['photos'] as num? ?? 0) + (r['vectors'] as num? ?? 0)).toInt(),
          ifAbsent: () => ((r['photos'] as num? ?? 0) + (r['vectors'] as num? ?? 0)).toInt());
    }
    return byNight.values.reduce((a, b) => a + b) ~/ byNight.length;
  }

  /// 남은 밤 수. 처리량을 아직 모르면 null
  int? get nightsLeft {
    final p = perNight;
    if (p == null || p == 0) return null;
    return ((total - done) / p).ceil().clamp(1, 999);
  }
}

// ───────────────────────────── 글자 모양

String fmtDate(int? ms, {bool time = false}) {
  if (ms == null) return '날짜 모름';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  final day = '${d.year}.${two(d.month)}.${two(d.day)}';
  return time ? '$day ${two(d.hour)}:${two(d.minute)}' : day;
}

/// "2026년 10월 12일", 올해면 "10월 12일"
String fmtDay(int ms, {bool year = false}) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return year || d.year != DateTime.now().year ? '${d.year}년 ${d.month}월 ${d.day}일' : '${d.month}월 ${d.day}일';
}

/// 순간의 날짜: 하루면 "10월 12일", 여러 날이면 "10월 12일 – 13일" / "10월 30일 – 11월 2일"
String fmtRange(int start, int end) {
  final a = DateTime.fromMillisecondsSinceEpoch(start), b = DateTime.fromMillisecondsSinceEpoch(end);
  final head = fmtDay(start);
  if (a.year == b.year && a.month == b.month && a.day == b.day) return head;
  if (a.year == b.year && a.month == b.month) return '$head – ${b.day}일';
  if (a.year == b.year) return '$head – ${b.month}월 ${b.day}일';
  return '$head – ${fmtDay(end, year: true)}';
}

String fmtTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final pm = d.hour >= 12;
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${pm ? '오후' : '오전'} $h:${d.minute.toString().padLeft(2, '0')}';
}

/// "엄마와" / "아들과": 마지막 글자에 받침이 있으면 '과'
String withWa(String s) {
  final c = s.isEmpty ? 0 : s.runes.last;
  final batchim = c >= 0xAC00 && c <= 0xD7A3 && (c - 0xAC00) % 28 != 0;
  return '$s${batchim ? '과' : '와'}';
}

String fmtInt(num v) => v.toInt().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// 화면에 쓸 인물 이름: "이름(관계)" — 이름과 관계가 같으면 하나만
String personLabel(Map<String, dynamic> p) {
  final r = p['relation'] as String?;
  return r == null || r == p['name'] ? p['name'] as String : '${p['name']}($r)';
}

/// 등록한 인물 목록 (id, name, relation, birth_year, n, refs, face)
Future<List<Map<String, dynamic>>> loadPeople() async =>
    ((await channel.invokeMethod('people')) as List).map((e) => Map<String, dynamic>.from(e)).toList();

// ───────────────────────────── 공용 위젯

/// 화면 제목: 큰 글씨 한 줄 + 오른쪽 버튼
class PageTitle extends StatelessWidget {
  const PageTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.headlineSmall)),
          ?trailing,
        ]),
      );
}

/// 묶음 제목 (작은 굵은 글씨)
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          ?trailing,
        ]),
      );
}

/// 둥근 원 안의 얼굴. 얼굴이 없으면 이름 첫 글자
class FaceAvatar extends StatelessWidget {
  const FaceAvatar({super.key, this.face, this.label = '', this.size = 56});
  final int? face;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: face == null
            ? Container(
                color: cs.secondaryContainer,
                alignment: Alignment.center,
                child: label.isEmpty
                    ? Icon(Icons.person_outline, size: size * 0.45, color: cs.onSecondaryContainer)
                    : Text(label.characters.first, style: TextStyle(fontSize: size * 0.36, color: cs.onSecondaryContainer)),
              )
            : Thumb(face!, face: true, size: size > 90 ? 320 : 256), // 크게 보이는 얼굴은 더 크게 잘라 온다
      ),
    );
  }
}

/// 진행 막대 (둥근 끝)
class Bar extends StatelessWidget {
  const Bar(this.value, {super.key, this.height = 6});
  final double? value;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: LinearProgressIndicator(
            value: value, minHeight: height, backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest),
      );
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = '확인', bool danger = false}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, minimumSize: const Size(0, 44)) : FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(ok),
          ),
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
        TextField(controller: relation, decoration: const InputDecoration(labelText: '나와의 관계 (선택)', hintText: '예: 딸, 아내, 조카 — 검색에 써요')),
        TextField(controller: birth, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '태어난 해 (선택)', hintText: '예: 2022 — 사진마다 그때 나이를 보여 줘요')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
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

/// 사진 목록 화면(순간·인물·자동 묶음). load가 {id, face} 목록을 주면(자동 묶음) 묶인 얼굴을 귀퉁이에 보인다
class PhotosPage extends StatefulWidget {
  const PhotosPage({super.key, required this.title, required this.load, this.subtitle, this.header});
  final String title;
  final String? subtitle;
  final Widget? header;
  final Future<dynamic> Function() load;

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> {
  List<int>? ids;
  final faces = <int, int>{}; // 사진 → 귀퉁이에 보일 얼굴

  @override
  void initState() {
    super.initState();
    widget.load().then((r) {
      if (!mounted) return;
      setState(() => ids = (r as List).map((e) {
            if (e is Map) {
              final id = (e['id'] as num).toInt();
              if (e['face'] != null) faces[id] = (e['face'] as num).toInt();
              return id;
            }
            return (e as num).toInt();
          }).toList());
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title),
            if (widget.subtitle != null || ids != null)
              Text(widget.subtitle ?? '사진 ${fmtInt(ids!.length)}장', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        body: ids == null
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(slivers: [
                if (widget.header != null) SliverToBoxAdapter(child: widget.header),
                SliverPadding(
                  padding: const EdgeInsets.all(2),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                    delegate: SliverChildBuilderDelegate(childCount: ids!.length, (context, i) {
                      final face = faces[ids![i]];
                      return GestureDetector(
                        onTap: () => showPhoto(context, ids![i], ids: ids),
                        child: face == null
                            ? Thumb(ids![i])
                            : Stack(fit: StackFit.expand, children: [
                                Thumb(ids![i]),
                                Align(
                                  alignment: Alignment.bottomRight,
                                  child: FractionallySizedBox(
                                    widthFactor: 0.42,
                                    heightFactor: 0.42,
                                    child: Container(
                                      margin: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                                      child: ClipOval(child: Thumb(face, face: true)),
                                    ),
                                  ),
                                ),
                              ]),
                      );
                    }),
                  ),
                ),
              ]),
      );
}

/// 썸네일은 Kotlin이 MediaStore에서 만들어 JPEG로 준다. 최근 것만 메모리에 둔다.
class Thumb extends StatelessWidget {
  const Thumb(this.id, {super.key, this.size = 256, this.face = false, this.fit = BoxFit.cover});
  final int id;
  final int size;
  final bool face;
  final BoxFit fit;

  static final _cache = <String, Future<Uint8List?>>{};
  static final _big = <int, Future<Uint8List?>>{}; // 크게 보기용 원본 축소본: 커서 몇 장만 둔다

  /// 크게 보기용: 원본을 긴 변 1600px로 줄인 것 (썸네일은 크게 늘리면 뭉개진다)
  static Future<Uint8List?> full(int id) {
    final f = _big.remove(id) ?? channel.invokeMethod<Uint8List>('photo', {'id': id, 'max': 1600}).catchError((_) => bytes(id, 1024));
    _big[id] = f;
    if (_big.length > 8) _big.remove(_big.keys.first);
    return f;
  }

  static Future<Uint8List?> bytes(int id, int size, {bool face = false}) {
    final key = '$face/$id/$size';
    final hit = _cache.remove(key);
    final f = hit ?? (face
        ? channel.invokeMethod<Uint8List>('faceThumb', {'id': id, 'size': size == 256 ? 160 : size})
        : channel.invokeMethod<Uint8List>('thumb', {'id': id, 'size': size}));
    _cache[key] = f; // 맨 뒤로 = 최근
    if (_cache.length > 400) _cache.remove(_cache.keys.first);
    return f;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: bytes(id, size, face: face),
        builder: (context, snap) => snap.data == null
            ? Container(color: Theme.of(context).colorScheme.surfaceContainerHighest)
            : Image.memory(snap.data!, fit: fit, gaplessPlayback: true),
      );
}

/// 사진 위에 얼굴 상자. 얼굴 위치는 사진 대비 0~1이라, 디코드한 사진 비율대로 자리를 잡고 그 위에 그린다
class FacePhoto extends StatefulWidget {
  const FacePhoto(this.id, {super.key, this.faces = const [], this.names = const {}, this.who, this.onFace, this.showBoxes = true});
  final int id;
  final List<Map<String, dynamic>> faces;
  final Map<int, String> names;
  final int? who;
  final bool showBoxes;
  final void Function(Map<String, dynamic> face)? onFace;

  @override
  State<FacePhoto> createState() => _FacePhotoState();
}

class _FacePhotoState extends State<FacePhoto> {
  late final Future<(Uint8List, ui.Image)?> image = _load();

  Future<(Uint8List, ui.Image)?> _load() async {
    final data = await Thumb.full(widget.id);
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
                  if (!widget.showBoxes) return;
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
                  if (widget.showBoxes) CustomPaint(painter: _FaceBoxes(widget.faces, widget.names, widget.who)),
                ]),
              ),
            ),
          );
        },
      );
}

/// 얼굴 상자: 둥근 흰 테두리, 이름표는 흰 바탕 둥근 글자. 맞는지 모르는 얼굴은 이름 뒤에 '?'
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
      final mine = who != null && (person == who || maybe == who);
      final r = Rect.fromLTWH((f['x'] as num) * size.width, (f['y'] as num) * size.height,
          (f['w'] as num) * size.width, (f['h'] as num) * size.height);
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.18)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = mine ? 3 : 2
            ..color = person != null || mine ? Colors.white : Colors.white60);
      final id = person ?? maybe;
      if (id == null || names[id] == null) continue;
      final tp = TextPainter(
        text: TextSpan(text: '${names[id]}${maybe != null ? '?' : ''}',
            style: const TextStyle(color: Color(0xFF111827), fontSize: 12, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      // 사진 밖으로 글자가 잘리지 않게: 얼굴 아래에, 오른쪽 끝에서는 왼쪽으로 민다
      final w = tp.width + 12, h = tp.height + 4;
      final x = r.center.dx.clamp(w / 2, size.width - w / 2) - w / 2;
      final y = (r.bottom + 4).clamp(0.0, size.height - h);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), const Radius.circular(8)), Paint()..color = Colors.white);
      tp.paint(canvas, Offset(x + 6, y + 2));
    }
  }

  @override
  bool shouldRepaint(_FaceBoxes old) => old.faces != faces || old.names != names || old.who != who;
}
