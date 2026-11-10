part of '../main.dart';

// ───────────────────────────── 설정: 화면 · 사진 정리 · 검색 · 정보 (진단 정보는 안쪽으로)

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String gender = ''; // 사용자 성별: '남', '여', ''(정하지 않음)

  @override
  void initState() {
    super.initState();
    channel.invokeMethod<String>('gender').then((g) => mounted ? setState(() => gender = g ?? '') : null).catchError((_) => null);
  }

  void go(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget group(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionLabel(title),
            Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < children.length; i++) ...[if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16), children[i]]])),
          ]),
        );
    Widget link(String title, {String? sub, VoidCallback? onTap, Color? color}) => ListTile(
          title: Text(title, style: TextStyle(color: color)),
          subtitle: sub == null ? null : Text(sub),
          trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          onTap: onTap,
        );
    return ListView(children: [
      const PageTitle('설정'),
      ValueListenableBuilder(
        valueListenable: Look.current,
        builder: (context, look, _) => group('화면', [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('대표 색', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              // 한 줄에 6개: 좁은 폰에서도 줄이 넘어가지 않게 칸을 나눠 가진다. 어두운 화면에서 먹색이 묻히지 않게 옅은 테두리
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                for (var i = 0; i < Look.accents.length; i++)
                  Semantics(
                    label: Look.accents[i].$2,
                    selected: look.accentIndex == i,
                    button: true,
                    child: InkResponse(
                      radius: 26,
                      onTap: () => Look.set(accent: i),
                      child: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Look.accents[i].$1,
                          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
                        ),
                        child: look.accentIndex == i ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                      ),
                    ),
                  ),
              ]),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('화면 모드', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('시스템')),
                  ButtonSegment(value: ThemeMode.light, label: Text('밝게')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('어둡게')),
                ],
                selected: {look.mode},
                onSelectionChanged: (s) => Look.set(mode: s.first),
              ),
            ]),
          ),
        ]),
      ),
      ListenableBuilder(
        listenable: Status.i,
        builder: (context, _) {
          final st = Status.i;
          return group('사진 정리', [
            SwitchListTile(
              title: const Text('충전 중에 자동 정리'),
              subtitle: const Text('폰이 뜨거워지거나 폰을 쓰면 잠시 쉬어요'),
              value: st.nightOn,
              onChanged: (on) async {
                await channel.invokeMethod('setNight', {'on': on});
                Status.i.refresh();
              },
            ),
            link('정리 상태', sub: st.ready ? '${(st.progress * 100).floor()}% · ${etaText(st)}' : null, onTap: () => go(const NightPage())),
            link('권한과 배터리 설정', sub: st.permission && st.batteryOk ? '모두 허용됨' : '확인이 필요해요', onTap: () => go(const PermissionsPage())),
          ]);
        },
      ),
      group('검색', [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('나의 성별', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text("'엄마의 딸'처럼 가족 관계로 찾을 때 누가 나인지 알아보는 데 써요", style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            // 검색어 관계 풀이에서 맞지 않는 후보를 뺀다(#10, 예: 남자면 '엄마 입장의 딸'은 내가 아니다)
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: '남', label: Text('남')),
                ButtonSegment(value: '여', label: Text('여')),
                ButtonSegment(value: '', label: Text('정하지 않음')),
              ],
              selected: {gender},
              onSelectionChanged: (s) async {
                await channel.invokeMethod('setGender', {'g': s.first.isEmpty ? null : s.first});
                setState(() => gender = s.first);
              },
            ),
          ]),
        ),
      ]),
      group('정보', [
        link('개인정보 처리방침', onTap: () => go(const PrivacyPage())),
        link('오픈소스 라이선스', onTap: () => showLicensePage(context: context, applicationName: '추억먹는하마')),
        link('진단 정보', sub: '정리 기록, 인물 찾기에서 뺀 이미지', onTap: () => go(const DiagnosticsPage())),
      ]),
      const SizedBox(height: 16),
    ]);
  }
}

/// 개인정보 처리방침 (앱 안 요약). 출시 전 웹 주소에 같은 내용을 올린다
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    const items = [
      ('모으는 정보', '없어요. 이 앱은 사진, 얼굴, 검색어를 어디에도 보내지 않아요. 가입이나 로그인도 없어요.'),
      ('폰 안에서 하는 일', '갤러리 사진을 읽어 찍은 날짜를 정리하고, 얼굴과 장면을 분석해 폰 안 저장소에 둬요. 원본 사진은 바꾸거나 지우지 않아요.'),
      ('권한', '사진 보기: 사진을 정리하려고. 알림: 정리하는 동안 진행 상황을 보여 주려고. 배터리 제한 해제: 충전 중에 정리가 멈추지 않게.'),
      ('지우기', '앱을 지우면 분석한 내용도 모두 함께 지워져요.'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('개인정보 처리방침')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        for (final (t, b) in items) ...[
          Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(b, style: const TextStyle(height: 1.6)),
          const SizedBox(height: 20),
        ],
      ]),
    );
  }
}

/// 진단 정보: 정리 기록(밤 작업마다 한 줄), 인물 찾기에서 뺀 이미지, 시험용 지금 시작 — 문제를 알릴 때 보는 곳
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  List<Map<String, dynamic>> runs = [];
  List<int> fakes = [0, 0]; // 인물 찾기에서 뺀 이미지: 화면 캡처, 만든 이미지(AI 그림·연예인 사진)
  String? exported;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await channel.invokeMethod('runs');
    final f = await channel.invokeMethod('fakeCounts');
    if (mounted) {
      setState(() {
        runs = (r as List).map((e) => Map<String, dynamic>.from(e)).toList();
        fakes = (f as List).cast<int>();
      });
    }
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

  Widget fakeTile(int kind, String title, String sub) => ListTile(
        leading: Icon(kind == 1 ? Icons.screenshot_outlined : Icons.auto_awesome_outlined),
        title: Text('$title ${fmtInt(fakes[kind - 1])}장'),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => PhotosPage(title: title, load: () => channel.invokeMethod('fakePhotos', {'kind': kind})))),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('진단 정보')),
        body: RefreshIndicator(
          onRefresh: load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            const SectionLabel('인물 찾기에서 뺀 이미지'),
            Card(
              child: Column(children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text('실제 사진이 아니라고 보고 얼굴을 짐작하지 않는 이미지예요. 검색에는 그대로 나와요.'),
                ),
                fakeTile(1, '화면 캡처', '스크린샷, 대화·쇼핑 화면 등'),
                fakeTile(2, '만든 이미지', 'AI 그림, 연예인·광고 사진 등'),
              ]),
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: Status.i,
              builder: (context, _) {
                final st = Status.i;
                return Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: st.permission && !st.running && !st.scanning
                          ? () async { await channel.invokeMethod('startNow'); Status.i.refresh(); }
                          : null,
                      child: const Text('지금 정리 시작 (충전 없이)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: st.running ? () async { await channel.invokeMethod('stopNow'); Status.i.refresh(); } : null,
                    child: const Text('멈춤'),
                  ),
                ]);
              },
            ),
            const SectionLabel('정리 기록'),
            if (runs.isEmpty) const Text('아직 기록이 없어요.'),
            for (final r in runs)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    title: Text('${fmtDate(r['start'] as int, time: true)} → '
                        '${r['end'] != null ? fmtDate(r['end'] as int, time: true) : '?'} · ${r['mode'] == 'night' ? '자동' : '직접'}'),
                    subtitle: Text(line(r)),
                    isThreeLine: true,
                  ),
                ),
              ),
            const SectionLabel('개발용'),
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
        ),
      );
}
