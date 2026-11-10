part of '../main.dart';

// ───────────────────────────── 밤 정리를 친절하게 알려 주기: 홈 배너 · 첫날 카드 · 정리 상태 화면

/// 지금 정리 상태 하나 (아이콘, 제목, 설명). Indexer.rest()의 쉬는 이유를 사용자 말로 옮긴다
({IconData icon, String title, String body}) nightState(Status st) {
  if (!st.permission) {
    return (icon: Icons.photo_library_outlined, title: '사진 보기를 허용해 주세요', body: '사진을 읽을 수 있어야 정리할 수 있어요. 사진을 바꾸거나 지우지 않아요.');
  }
  if (st.scanning) {
    return (icon: Icons.photo_library_outlined, title: '사진 목록을 읽고 있어요', body: '찍은 날짜와 장소로 순간을 나누는 중이에요. 다른 앱으로 가도 계속돼요.');
  }
  if (st.running) {
    final why = st.restWhy;
    if (why == '사용 중') {
      return (icon: Icons.smartphone, title: '폰을 쓰는 동안 잠깐 멈췄어요', body: '폰이 느려지지 않게 화면이 켜져 있을 때는 쉬어요. 화면이 꺼지면 다시 시작해요.');
    }
    if (why != null) {
      return (
        icon: Icons.thermostat,
        title: '폰이 따뜻해서 잠시 쉬는 중이에요',
        body: '폰을 보호하려고 온도가 내려갈 때까지 쉬어요. 약 ${st.restLeftMin}분 뒤 알아서 이어서 해요. 아무것도 안 하셔도 돼요.'
      );
    }
    return (icon: Icons.bolt, title: '지금 정리하고 있어요', body: '정리된 사진은 바로 홈과 검색에 나와요. 폰을 쓰면 잠깐 멈췄다가 다시 해요.');
  }
  if (st.allDone) {
    return (icon: Icons.check_circle_outline, title: '모든 사진을 정리했어요', body: '새로 찍은 사진은 다음에 충전할 때 조용히 정리해요.');
  }
  if (!st.nightOn) {
    return (icon: Icons.nightlight_outlined, title: '자동 정리가 꺼져 있어요', body: '켜 두면 충전 중일 때 알아서 정리해요.');
  }
  return (icon: Icons.nightlight_outlined, title: '충전기를 꽂으면 시작해요', body: '정리는 충전 중일 때만 해요. 오늘 밤 자기 전에 충전기를 꽂아 두세요.');
}

/// "약 3일 밤 남음" — 지난 밤 처리량을 모르면 첫날 안내
String etaText(Status st) {
  if (st.allDone) return '완료';
  if (!st.nightOn && !st.running) return '자동 정리를 켜면 이어서 해요';
  final n = st.nightsLeft;
  return n == null ? '처음 며칠 밤 걸려요' : n <= 1 ? '오늘 밤이면 끝나요' : '약 $n일 밤 남음';
}

/// 홈 위쪽 얇은 상태 카드. 누르면 정리 상태 화면
class NightBanner extends StatelessWidget {
  const NightBanner({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Status.i,
        builder: (context, _) {
          final st = Status.i;
          if (!st.ready || st.allDone || st.untouched && !st.running && !st.scanning) return const SizedBox.shrink();
          final s = nightState(st);
          final cs = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              child: InkWell(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NightPage())),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(s.icon, size: 18, color: cs.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text('${(st.progress * 100).floor()}%', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                    ]),
                    const SizedBox(height: 10),
                    Bar(st.scanning ? null : st.progress),
                    const SizedBox(height: 8),
                    Text.rich(TextSpan(children: [
                      TextSpan(text: '정리된 사진부터 보여 드려요 · ${etaText(st)} · '),
                      TextSpan(text: '자세히', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
                    ]), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}

/// 첫날(아직 아무것도 정리 안 함): 오늘 밤 준비 체크리스트 + 자주 묻는 질문
class FirstNightCard extends StatelessWidget {
  const FirstNightCard({super.key});

  static const faq = [
    ('왜 바로 정리하지 않나요?', '사진 한 장마다 얼굴과 장면을 분석해서 폰이 뜨거워지고 배터리를 많이 써요. 그래서 폰을 쓰지 않는 충전 중인 시간에 나눠서 해요.'),
    ('배터리가 닳거나 폰에 무리가 가지 않나요?', '충전 중일 때만 하고, 폰이 뜨거워지면 식을 때까지 쉬어요. 폰을 켜서 쓰면 그동안은 멈춰요.'),
    ('사진이 인터넷으로 나가나요?', '아니요. 모든 분석은 이 폰 안에서만 해요. 인터넷이 꺼져 있어도 똑같이 동작해요.'),
    ('그동안 무엇을 할 수 있나요?', '날짜별 순간은 지금도 볼 수 있어요. 인물과 장면 검색은 정리된 사진부터 하나씩 늘어나요.'),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Status.i,
        builder: (context, _) {
          final st = Status.i;
          if (!st.untouched || st.running) return const SizedBox.shrink();
          final cs = Theme.of(context).colorScheme;
          Widget check(bool ok, String label, String state) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Container(
                    width: 22, height: 22,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: ok ? cs.primary : cs.surfaceContainerHighest),
                    child: ok ? Icon(Icons.check, size: 14, color: cs.onPrimary) : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label)),
                  Text(state, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ]),
              );
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                  child: Column(children: [
                    CircleAvatar(radius: 32, backgroundColor: cs.primary.withValues(alpha: 0.1), child: Icon(Icons.nightlight_outlined, color: cs.primary, size: 30)),
                    const SizedBox(height: 12),
                    Text('첫 정리는 오늘 밤에 시작해요', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text('자기 전에 충전기만 꽂아 두세요.\n내일 아침부터 인물과 장면으로 찾을 수 있어요.',
                        textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, height: 1.5)),
                    const SizedBox(height: 14),
                    check(st.permission, '사진 보기 허용', st.permission ? '완료' : '필요'),
                    check(st.batteryOk, '배터리 제한 풀기', st.batteryOk ? '완료' : '권장'),
                    check(false, '충전기 연결', '오늘 밤'),
                    if (!st.permission || !st.batteryOk)
                      TextButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PermissionsPage())),
                        child: const Text('지금 설정하기'),
                      ),
                    TextButton(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NightPage())),
                      child: const Text('정리가 어떻게 되는지 자세히 보기'),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  for (final (q, a) in faq)
                    ExpansionTile(
                      shape: const Border(),
                      title: Text(q, style: const TextStyle(fontSize: 15)),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      expandedAlignment: Alignment.centerLeft,
                      children: [Text(a, style: TextStyle(color: cs.onSurfaceVariant, height: 1.5))],
                    ),
                ]),
              ),
            ]),
          );
        },
      );
}

/// 정리 상태 자세히: 지금 상태와 이유, 남은 양, 지난밤 요약, 더 빨리 끝내는 요령
class NightPage extends StatelessWidget {
  const NightPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('사진 정리')),
        body: ListenableBuilder(
          listenable: Status.i,
          builder: (context, _) {
            final st = Status.i;
            if (!st.ready) return const Center(child: CircularProgressIndicator());
            final s = nightState(st);
            final cs = Theme.of(context).colorScheme;
            final last = st.runs.where((r) => r['mode'] == 'night').firstOrNull;
            Widget stat(String v, String label) => Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  ]),
                );
            Widget tip(String t) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('·  ', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700)),
                    Expanded(child: Text(t, style: const TextStyle(height: 1.5))),
                  ]),
                );
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      CircleAvatar(radius: 26, backgroundColor: cs.primary.withValues(alpha: 0.1), child: Icon(s.icon, color: cs.primary)),
                      const SizedBox(width: 14),
                      Expanded(child: Text(s.title, style: Theme.of(context).textTheme.titleMedium)),
                    ]),
                    const SizedBox(height: 14),
                    Text(s.body, style: const TextStyle(height: 1.55)),
                    const SizedBox(height: 16),
                    Bar(st.scanning ? null : st.progress, height: 8),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: Text('${(st.progress * 100).floor()}% 정리됨', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant))),
                      Text(etaText(st), style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                    ]),
                    if (!st.nightOn && !st.allDone) ...[
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () async {
                          await channel.invokeMethod('setNight', {'on': true});
                          Status.i.refresh();
                        },
                        child: const Text('자동 정리 켜기'),
                      ),
                    ],
                    if (!st.permission) ...[
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PermissionsPage())),
                        child: const Text('권한 설정하기'),
                      ),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('정리한 것', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    Row(children: [
                      stat(fmtInt(st.photos), '사진'),
                      stat(fmtInt(st.segments), '순간'),
                      stat(fmtInt((st.s?['faces'] as num?) ?? 0), '찾은 얼굴'),
                    ]),
                  ]),
                ),
              ),
              if (last != null) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('지난번 정리 · ${fmtDay((last['start'] as num).toInt())}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      Row(children: [
                        stat(fmtInt(((last['photos'] as num? ?? 0) + (last['vectors'] as num? ?? 0))), '정리한 사진'),
                        stat(_hours(last), '정리한 시간'),
                        stat('${last['rests'] ?? 0}번', '식히려고 쉼'),
                      ]),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('더 빨리 끝내려면', style: TextStyle(fontWeight: FontWeight.w700)),
                    tip('자기 전에 충전기를 꽂고 화면을 꺼 두세요.'),
                    tip('두꺼운 케이스나 이불 속은 폰이 금방 뜨거워져서 자주 쉬어요.'),
                    tip('정리 중에 앱을 닫아도 괜찮아요. 원본 사진은 건드리지 않고, 다음에 이어서 해요.'),
                    if (!st.batteryOk) tip('배터리 제한을 풀어 두면 밤사이 멈추지 않아요. 설정 › 권한과 배터리에서 바꿀 수 있어요.'),
                  ]),
                ),
              ),
            ]);
          },
        ),
      );

  static String _hours(Map<String, dynamic> r) {
    final end = (r['end'] ?? r['last']) as num?;
    if (end == null) return '-';
    final m = ((end - (r['start'] as num)) / 60000).round();
    return m < 60 ? '$m분' : '${(m / 60).toStringAsFixed(m < 600 ? 1 : 0)}시간';
  }
}
