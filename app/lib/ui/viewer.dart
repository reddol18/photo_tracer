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
  final infos = <int, Map<String, dynamic>>{};
  List<Map<String, dynamic>> people = [];

  int get id => widget.ids[index];
  Map<String, dynamic>? get info => infos[id];

  // ── 확대/축소와 넘기기(#12): 확대 중이거나 손가락이 2개 이상이면 PageView 넘기기를 끈다
  final zooms = <int, TransformationController>{}; // 페이지 번호 → 배율
  final fingers = <int>{}; // 지금 화면에 닿은 손가락(포인터 id)
  bool zoomed = false; // 지금 페이지가 확대돼 있나
  int downPage = 0; // 첫 손가락이 닿을 때의 페이지 — 두 번째 손가락이 늦게 닿으면 여기로 되돌린다
  Offset tapAt = Offset.zero; // 두 번 탭한 곳(확대 중심)
  bool get locked => zoomed || fingers.length >= 2;

  static const zoomStep = 2.5;
  static bool isZoomed(TransformationController c) => c.value.getMaxScaleOnAxis() > 1.01;

  TransformationController zoomOf(int i) => zooms.putIfAbsent(i, () => TransformationController()..addListener(() => onZoom(i)));

  void onZoom(int i) {
    if (i != index || !mounted) return;
    final z = isZoomed(zooms[i]!);
    if (z != zoomed) setState(() => zoomed = z);
  }

  void fingerDown(PointerDownEvent e) {
    if (fingers.isEmpty && pages.hasClients) downPage = (pages.page ?? index.toDouble()).round();
    fingers.add(e.pointer);
    if (fingers.length != 2) return;
    // 넘기기를 끄면(setCanDrag false) Scrollable이 진행 중 드래그를 취소한다. 그 뒤 절반 넘게 끌렸던 페이지도 처음 페이지로 되돌린다
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !pages.hasClients || pages.page == null) return;
      if ((pages.page! - downPage).abs() > 0.001) {
        pages.animateToPage(downPage, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      }
    });
  }

  void fingerUp(PointerEvent e) {
    if (fingers.remove(e.pointer) && fingers.length == 1) setState(() {});
  }

  /// 두 번 탭: 원래 크기면 누른 곳을 중심으로 확대, 확대돼 있으면 원래대로
  void doubleTap() {
    final c = zoomOf(index);
    if (isZoomed(c)) {
      c.value = Matrix4.identity();
    } else {
      c.value = Matrix4.diagonal3Values(zoomStep, zoomStep, 1)
        ..setTranslationRaw(-tapAt.dx * (zoomStep - 1), -tapAt.dy * (zoomStep - 1), 0);
    }
  }

  void onShowFaces() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ShowFaces.on.addListener(onShowFaces);
    loadPeople().then((p) => mounted ? setState(() => people = p) : null);
    load(id);
  }

  @override
  void dispose() {
    ShowFaces.on.removeListener(onShowFaces);
    for (final c in zooms.values) {
      c.dispose();
    }
    pages.dispose();
    super.dispose();
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
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
    final showFaces = ShowFaces.on.value;
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
            // 손가락 수는 PageView 바깥에서 센다(제스처 경쟁과 상관없이 모든 포인터를 본다)
            child: Listener(
              onPointerDown: fingerDown,
              onPointerUp: fingerUp,
              onPointerCancel: fingerUp,
              child: PageView.builder(
                controller: pages,
                physics: locked ? const NeverScrollableScrollPhysics() : null,
                itemCount: widget.ids.length,
                onPageChanged: (i) {
                  setState(() {
                    index = i;
                    // 다른 페이지로 넘어가면 나머지 페이지 배율은 원래대로
                    for (final e in zooms.entries) {
                      if (e.key != i) e.value.value = Matrix4.identity();
                    }
                    zoomed = zooms[i] != null && isZoomed(zooms[i]!);
                  });
                  if (!infos.containsKey(widget.ids[i])) load(widget.ids[i]);
                },
                itemBuilder: (context, i) {
                  final pid = widget.ids[i];
                  final y = infos[pid]?['taken'] == null ? null : DateTime.fromMillisecondsSinceEpoch(infos[pid]!['taken'] as int).year;
                  // 확대 영역은 페이지 전체: 사진 위아래 빈 곳에서 시작해도 확대된다. 얼굴 상자는 사진 위젯 안에 그려지고
                  // 누른 곳도 변환을 거쳐 사진 좌표로 오므로 확대 상태에서도 맞다
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTapDown: (d) => tapAt = d.localPosition,
                    onDoubleTap: doubleTap,
                    child: InteractiveViewer(
                      key: ValueKey('zoom-$i'),
                      transformationController: zoomOf(i),
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: FacePhoto(pid, key: ValueKey('$pid/${infos[pid]?.hashCode}'), faces: facesOf(pid), names: labelsFor(y),
                            who: widget.who, onFace: onFace, showBoxes: showFaces, zoom: zoomOf(i)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (faces.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                      !showFaces
                          ? '얼굴 ${faces.length}개 · 얼굴 박스를 켜면 고칠 수 있어요'
                          : who.isEmpty ? '얼굴 ${faces.length}개 · 얼굴을 눌러 누구인지 알려 주세요' : '$who · 얼굴을 눌러 고칠 수 있어요',
                      style: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 13)),
                ),
                // 얼굴 상자·이름표를 켜고 끄는 토글. 사진 속 얼굴을 가리는 기능으로 읽히지 않게 글자는 늘 '얼굴 박스'이고
                // 켜짐은 체크 + 채운 배경으로 보인다. TalkBack은 Semantics 하나만 읽게(버튼 자체 읽기는 뺌)
                Semantics(
                  button: true,
                  toggled: showFaces,
                  label: '얼굴 박스',
                  excludeSemantics: true,
                  onTap: () => ShowFaces.set(!showFaces),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.padded, // 터치 영역 48
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      foregroundColor: showFaces ? Colors.white : fg,
                      backgroundColor: showFaces ? const Color(0xFF2563EB) : Colors.transparent,
                      side: BorderSide(color: showFaces ? const Color(0xFF2563EB) : const Color(0xFF4B5563)),
                    ),
                    onPressed: () => ShowFaces.set(!showFaces),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (showFaces) ...[const Icon(Icons.check, size: 16), const SizedBox(width: 4)],
                      const Text('얼굴 박스', style: TextStyle(fontSize: 13)),
                    ]),
                  ),
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
