part of '../main.dart';

// ───────────────────────────── 이 사람 맞나요? (확인 필요 얼굴을 한 장씩)

class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  List<Map<String, dynamic>>? items;
  Map<int, Map<String, dynamic>> people = {};
  int total = 0, answered = 0, at = 0;
  bool saving = false;
  final skipped = <Object?>{};
  final pending = <Future<void>>[];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (pending.isNotEmpty) {
      setState(() => saving = true);
      await Future.wait(pending);
      pending.clear();
      if (!mounted) return;
      setState(() => saving = false);
    }
    final r = Map<String, dynamic>.from(await channel.invokeMethod('reviewQueue', {'limit': 100}) as Map);
    final p = await loadPeople();
    if (!mounted) return;
    setState(() {
      people = {for (final e in p) e['id'] as int: e};
      // 건너뛴 얼굴은 이번에는 다시 묻지 않는다
      items = (r['items'] as List).map((e) => Map<String, dynamic>.from(e)).where((e) => !skipped.contains(e['face'])).toList();
      total = (r['total'] as num).toInt() + answered;
      at = 0;
    });
  }

  Map<String, dynamic>? get cur => items != null && at < items!.length ? items![at] : null;

  /// ok: true 맞아요, false 아니에요, null 건너뛰기
  Future<void> answer(bool? ok) async {
    final f = cur;
    if (f == null || saving) return;
    if (ok != null) {
      // 답할 때마다 인물을 다시 붙여서(Who.assignAll, 1초쯤) 기다리지 않고 다음 사진으로 넘어간다.
      // 채널 작업은 한 줄로 차례대로 돌고, 다음 묶음을 부르기 전에 모두 끝나기를 기다린다
      pending.add(channel.invokeMethod('whoMark', {'id': f['person'], 'faces': [f['face']], 'ok': ok}));
      answered++;
    } else {
      skipped.add(f['face']);
    }
    if (!mounted) return;
    setState(() => at++);
    if (at >= items!.length) load(); // 한 묶음을 다 보면 다음 묶음 (답한 얼굴은 빠진다)
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = cur;
    final left = (total - answered - skipped.length).clamp(0, 1 << 30);
    final p = f == null ? null : people[f['person'] as int];
    return Scaffold(
      appBar: AppBar(
        title: Text(items == null ? '' : f == null ? '확인 끝' : '${fmtInt(left)}장 남음', style: const TextStyle(fontSize: 15)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Bar(total == 0 ? 1 : answered / total, height: 4),
          ),
        ),
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : f == null || p == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircleAvatar(radius: 32, backgroundColor: cs.primary.withValues(alpha: 0.1), child: Icon(Icons.check, color: cs.primary, size: 32)),
                      const SizedBox(height: 16),
                      Text(answered > 0 ? '모두 확인했어요. 고마워요!' : '지금은 확인할 사진이 없어요', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(skipped.isEmpty ? '알려 주신 내용은 바로 반영돼요.' : '건너뛴 사진은 다음에 다시 여쭤볼게요.',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 24),
                      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('돌아가기')),
                    ]),
                  ),
                )
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: '이 사람이 '),
                          TextSpan(text: p['name'] as String, style: TextStyle(color: cs.primary)),
                          const TextSpan(text: ' 맞나요?'),
                        ]),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 6),
                      Text('닮았지만 확실하지 않은 얼굴이에요', style: TextStyle(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 20),
                      Expanded(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(
                                child: Center(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(18),
                                    child: FacePhoto(f['photo'] as int,
                                        key: ValueKey(f['face']),
                                        faces: [{...f, 'id': f['face'], 'who': null, 'maybe': f['person']}],
                                        names: const {},
                                        who: f['person'] as int),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(f['taken'] == null ? '찍은 날 모름' : fmtDay(f['taken'] as int, year: true),
                                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                            ]),
                          ),
                          const SizedBox(width: 12),
                          Column(mainAxisSize: MainAxisSize.min, children: [
                            FaceAvatar(face: p['face'] as int?, label: p['name'] as String, size: 72),
                            const SizedBox(height: 6),
                            Text('등록한 얼굴', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                            const SizedBox(height: 18),
                          ]),
                        ]),
                      ),
                      const SizedBox(height: 20),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
                            onPressed: saving ? null : () => answer(false),
                            child: const Text('아니에요'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                            onPressed: saving ? null : () => answer(true),
                            child: const Text('맞아요'),
                          ),
                        ),
                      ]),
                      TextButton(onPressed: saving ? null : () => answer(null), child: const Text('잘 모르겠어요 · 건너뛰기')),
                    ]),
                  ),
                ),
    );
  }
}
