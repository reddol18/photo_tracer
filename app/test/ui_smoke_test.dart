// 화면마다 가짜 데이터로 그려 보아 레이아웃 오류(넘침·크기 없는 목록 등)가 없는지 본다. 폰 없이 PC에서 돈다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

final day = DateTime(2026, 10, 12, 15, 24).millisecondsSinceEpoch;

Map<String, dynamic> status({bool untouched = false, bool running = false, String? rest}) => {
      'photos_permission': true, 'notifications': true, 'battery_exempt': false, 'manufacturer': 'Xiaomi',
      'running': running, 'rest_why': rest, 'rest_left': 300, 'night_on': true, 'scan_phase': null, 'scan_done': 0, 'scan_total': 0,
      'photos': 9354, 'failed': 3, 'faces_done': untouched ? 0 : 3120, 'segments': 812,
      'vec_needed': 1200, 'vec_done': untouched ? 0 : 400, 'faces': 5021, 'reface_needed': 0, 'reface_done': 0, 'persons': 12,
    };

final people = [
  {'id': 1, 'name': '엄마', 'relation': null, 'birth_year': 1985, 'n': 1204, 'refs': 5, 'face': null},
  {'id': 2, 'name': '아주 긴 이름의 할아버지', 'relation': '할아버지', 'birth_year': null, 'n': 318, 'refs': 2, 'face': null},
  {'id': 3, 'name': '딸', 'relation': null, 'birth_year': 2018, 'n': 3402, 'refs': 9, 'face': null},
];

Map<String, dynamic> scenario = {};
final thumbSizes = <int, List<int>>{}; // 사진 id → 'thumb'로 요청받은 크기들
final searches = <String>[]; // 'search'로 받은 검색어들

Future<Object?> fake(MethodCall call) async {
  switch (call.method) {
    case 'thumb':
      thumbSizes.putIfAbsent((call.arguments['id'] as num).toInt(), () => []).add(call.arguments['size'] as int);
      return scenario['thumb']; // 기본은 그림 없음 → 빈 칸으로 그린다
    case 'pref':
      return scenario['pref.${call.arguments['key']}'];
    case 'status':
      return scenario['status'] ?? status();
    case 'runs':
      return [
        {'id': 1, 'mode': 'night', 'start': day, 'end': day + 5 * 3600000, 'last': day + 5 * 3600000, 'photos': 1240, 'faces': 900,
         'vectors': 300, 'face_ms': 1200.0, 'vec_ms': 900.0, 'rests': 2, 'max_temp': 41.5, 'stop': '충전 끊김', 'note': 'FGS'},
      ];
    case 'people':
      return people;
    case 'moments':
      if (scenario['moments'] != null) return call.arguments['offset'] == 0 ? scenario['moments'] : [];
      return [
        for (var i = 0; i < 5; i++)
          {'id': i, 'start': day - i * 86400000 * 9, 'end': day - i * 86400000 * 9 + 86400000, 'n': 48 - i * 10,
           'covers': [for (var k = 0; k < (i % 3) + 1; k++) 100 + k], 'people': [1, 3]},
      ];
    case 'momentPhotos':
    case 'segmentPhotos':
      return [101, 102, 103];
    case 'persons':
      return [
        {'id': 7, 'n': 84, 'face': 70, 'known': false},
        {'id': 8, 'n': 41, 'face': 71, 'known': true},
      ];
    case 'reviewQueue':
      return {'total': 37, 'items': [
        {'face': 900, 'photo': 101, 'person': 1, 'sim': 0.41, 'x': 0.3, 'y': 0.2, 'w': 0.2, 'h': 0.25, 'taken': day},
      ]};
    case 'clusterInfo':
      return {'running': 0, 'full_ms': 60000, 'full_faces': 4000, 'faces': 5021, 'full_at': day, 'added': 0, 'added_at': 0};
    case 'gender':
      return null;
    case 'fakeCounts':
      return [1916, 40];
    case 'whoPhotos':
      return [
        {'id': 101, 'face': 900, 'sim': 1.0, 'kind': 'ref', 'taken': day},
        {'id': 102, 'face': 901, 'sim': 0.4, 'kind': 'maybe', 'taken': null},
      ];
    case 'photoInfo':
      return {'taken': day, 'date_source': 'exif', 'received': null, 'faces': [
        {'id': 900, 'x': 0.3, 'y': 0.2, 'w': 0.2, 'h': 0.25, 'person': 7, 'who': 1, 'maybe': null, 'sim': 0.6},
      ]};
    case 'search':
      final q = call.arguments['q'] as String;
      searches.add(q);
      if (scenario['dynamicSearch'] == true) {
        // 검색어 낱말 중 등록 이름(조사 '과'·'와'·'의'를 떼고)은 인물 낱말, 나머지는 장면
        final ws = <Map<String, dynamic>>[];
        final rest = <String>[];
        for (final tok in q.split(' ')) {
          final f = tok.replaceAll(RegExp(r'(과|와|의)$'), '');
          final p = people.where((p) => (p['name'] as String).replaceAll(' ', '') == f).firstOrNull;
          if (p == null) {
            rest.add(tok);
          } else {
            ws.add({'word': f, 'chosen': [p['id']], 'cands': [{'ids': [p['id']], 'note': ''}]});
          }
        }
        return {'items': [{'kind': 'photo', 'cover': 102, 'date': day}], 'rest': rest.join(' '),
                'who': ws.isEmpty ? null : ws.map((w) => w['word']).join(' · '), 'photos': 1, 'words': ws, 'hint': false};
      }
      return {'items': [
        {'kind': 'segment', 'id': 1, 'cover': 101, 'n': 18, 'date': day, 'date_source': 'exif'},
        {'kind': 'photo', 'cover': 102, 'date': null, 'received': day},
      ], 'rest': '바다', 'who': null, 'words': [
        {'word': '딸', 'chosen': [3], 'cands': [{'ids': [3], 'note': '나의 딸'}, {'ids': [1], 'note': '엄마의 딸'}]},
      ], 'hint': true, 'candidates': 800, 'query_ms': 300, 'total_ms': 400};
    default:
      return null; // thumb·faceThumb 등: 그림 없음 → 빈 칸으로 그린다
  }
}

Future<void> show(WidgetTester t, Widget w, {Size size = const Size(390, 844)}) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  await t.pumpWidget(MaterialApp(theme: buildTheme(const Color(0xFF2563EB), Brightness.light), home: w));
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    scenario = {};
    thumbSizes.clear();
    searches.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, fake);
  });

  tearDown(() async {
    Status.i.stop();
  });

  Future<void> cleanup(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    Status.i.stop();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  }

  testWidgets('처음 실행 3단계', (t) async {
    await show(t, const OnboardingPage());
    expect(find.textContaining('떠나지 않아요'), findsOneWidget);
    await t.tap(find.text('계속하기'));
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('사진 보기 허용'), findsOneWidget);
    expect(find.textContaining('샤오미'), findsOneWidget);
    await t.tap(find.text('다음'));
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.textContaining('충전 중인'), findsWidgets);
    await cleanup(t);
  });

  testWidgets('홈: 정리 중 배너와 순간들', (t) async {
    await show(t, const Shell());
    expect(find.text('추억'), findsOneWidget);
    expect(find.textContaining('사진 48장'), findsOneWidget);
    await t.tap(find.text('딸').first);
    await t.pump(const Duration(milliseconds: 100));
    await cleanup(t);
  });

  testWidgets('홈: 콜라주 썸네일은 칸의 실제 픽셀에 맞는 크기로 요청한다', (t) async {
    // 다른 시험과 캐시가 겹치지 않게 처음 쓰는 사진 id로
    scenario['moments'] = [
      {'id': 90, 'start': day, 'end': day + 3600000, 'n': 12, 'covers': [7700, 7701, 7702], 'people': []},
    ];
    await show(t, const Shell()); // 기기 픽셀 비율 3
    expect(thumbSizes[7700], isNotNull);    expect(thumbSizes[7700]!.last, greaterThanOrEqualTo(768)); // 큰 칸: 폭 약 230dp × 3
    expect(thumbSizes[7701]!.last, greaterThanOrEqualTo(256)); // 작은 칸도 단계 중 하나
    expect(const [256, 384, 512, 768, 1024], containsAll([thumbSizes[7700]!.last, thumbSizes[7701]!.last]));
    await cleanup(t);
  });

  testWidgets('홈: 2장 카드의 가로 사진도 칸 높이를 꽉 채운다', (t) async {
    // 8x4 가로 PNG: 세로 제약이 느슨하면 비율대로 높이가 짧게 그려진다
    scenario['thumb'] = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXYxhwwMAAAACEAAHOfCFIAAAAAElFTkSuQmCC');
    scenario['moments'] = [
      {'id': 91, 'start': day, 'end': day + 3600000, 'n': 2, 'covers': [7800, 7801], 'people': []},
    ];
    await show(t, const Shell());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // 그림 풀기
    await t.pump();
    final images = find.byType(Image);
    expect(images, findsNWidgets(2));
    for (final e in images.evaluate()) {
      expect(e.size!.height, 150); // 2장 카드 칸 높이
    }
    expect(thumbSizes[7800]!.last, 768); // 칸 약 178x150dp, 긴 변 × 3 = 532px → 768
    await cleanup(t);
  });

  testWidgets('홈: 첫날 카드', (t) async {
    scenario['status'] = status(untouched: true);
    await show(t, const Shell());
    expect(find.text('첫 정리는 오늘 밤에 시작해요'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('정리 상태: 쉬는 중', (t) async {
    scenario['status'] = status(running: true, rest: '배터리 42.0℃');
    await t.runAsync(() => Status.i.refresh());
    await show(t, const NightPage());
    expect(find.text('폰이 따뜻해서 잠시 쉬는 중이에요'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('검색: 처음 화면 → 결과', (t) async {
    scenario['pref.recent'] = '벚꽃\n딸 졸업식';
    await show(t, const Scaffold(body: SearchPage()));
    expect(find.text('인물로 찾기'), findsOneWidget);
    expect(find.text('딸과 바다'), findsOneWidget); // 사진이 가장 많은 인물 + 받침이 있으면 '과'
    await t.tap(find.text('눈 오는 날'));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('장면: 바다'), findsOneWidget);
    await cleanup(t);
  });

  Future<void> settle(WidgetTester t) async {
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  testWidgets('검색: 결과 화면에서 인물 더하기(#14), 칩 ✕로 한 명씩 빼기(#15)', (t) async {
    scenario['dynamicSearch'] = true;
    await show(t, const Scaffold(body: SearchPage()));
    await t.tap(find.text('딸').first); // 처음 화면 얼굴 줄: 한 명 누르면 바로 결과
    await settle(t);
    expect(searches.last, '딸');
    expect(find.byTooltip('딸 빼기'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('face-1'))); // 결과 화면 얼굴 줄에서 엄마 더하기
    await settle(t);
    expect(searches.last, '딸 엄마');
    expect(find.byTooltip('딸 빼기'), findsOneWidget);
    expect(find.byTooltip('엄마 빼기'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('face-1'))); // 이미 든 사람은 다시 더하지 않고 뺀다
    await settle(t);
    expect(searches.last, '딸');
    await t.tap(find.byKey(const ValueKey('face-2'))); // 빈칸 있는 이름은 빈칸 없이
    await settle(t);
    expect(searches.last, '딸 아주긴이름의할아버지');
    await t.tap(find.byTooltip('딸 빼기'));
    await settle(t);
    expect(searches.last, '아주긴이름의할아버지');
    expect(find.byTooltip('딸 빼기'), findsNothing);
    final n = searches.length;
    await t.tap(find.byTooltip('아주긴이름의할아버지 빼기')); // 마지막 하나, 장면 말 없음 → 처음 화면
    await settle(t);
    expect(searches.length, n);
    expect(find.text('인물로 찾기'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('검색: 인물 낱말 앞쪽에 더하고, 다 빼면 장면만 검색', (t) async {
    scenario['dynamicSearch'] = true;
    await show(t, const Scaffold(body: SearchPage()));
    await t.tap(find.text('딸과 바다'));
    await settle(t);
    expect(searches.last, '딸과 바다');
    await t.tap(find.byKey(const ValueKey('face-1')));
    await settle(t);
    expect(searches.last, '딸과 엄마 바다'); // 맨 앞 인물 낱말들 뒤, 장면 말 앞
    await t.tap(find.byKey(const ValueKey('face-3'))); // 얼굴 줄 토글로 빼기: 조사 붙은 낱말째
    await settle(t);
    expect(searches.last, '엄마 바다');
    await t.tap(find.byTooltip('엄마 빼기'));
    await settle(t);
    expect(searches.last, '바다');
    expect(find.text('장면: 바다'), findsNothing); // 인물 칩이 없으면 '이렇게 이해했어요' 줄도 없다
    expect(find.text('인물로 찾기'), findsNothing); // 결과 화면 그대로
    await cleanup(t);
  });

  testWidgets('검색 결과: 좁은 화면 + 큰 글씨에서 얼굴 줄·칩 둘이 넘치지 않는다', (t) async {
    scenario['dynamicSearch'] = true;
    t.view.physicalSize = const Size(360, 700) * 3;
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(const Color(0xFF2563EB), Brightness.light),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
      home: const Scaffold(body: SearchPage()),
    ));
    await settle(t);
    await t.tap(find.text('딸과 바다'));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('face-2')));
    await settle(t);
    expect(searches.last, '딸과 아주긴이름의할아버지 바다');
    expect(find.byTooltip('아주긴이름의할아버지 빼기'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('인물', (t) async {
    await show(t, const Scaffold(body: PeoplePage()));
    expect(find.text('이 사람 맞나요? 37장'), findsOneWidget);
    expect(find.text('자주 보이는 얼굴'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('이 사람 맞나요?', (t) async {
    await show(t, const ReviewPage());
    expect(find.text('맞아요'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('인물 한 명', (t) async {
    await show(t, const WhoPage(id: 1));
    expect(find.textContaining('직접 고른 사진'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('설정 · 진단 · 개인정보', (t) async {
    await show(t, const Scaffold(body: SettingsPage()), size: const Size(390, 1400));
    expect(find.text('대표 색'), findsOneWidget);
    await show(t, const DiagnosticsPage());
    expect(find.textContaining('화면 캡처'), findsOneWidget);
    await show(t, const PrivacyPage());
    await cleanup(t);
  });

  testWidgets('사진 크게 보기', (t) async {
    await show(t, const PhotoViewer(ids: [101, 102, 103], start: 1));
    expect(find.text('공유'), findsOneWidget);
    expect(find.text('2 / 3'), findsNothing); // 시각과 함께 한 줄
    expect(find.textContaining('2 / 3'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('좁은 화면 + 큰 글씨(1.3배)에서도 넘치지 않는다', (t) async {
    t.view.physicalSize = const Size(340, 700) * 3;
    t.view.devicePixelRatio = 3;
    Widget big(Widget w) => MaterialApp(
          theme: buildTheme(const Color(0xFF2563EB), Brightness.light),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
          home: w,
        );
    for (final w in [
      const Shell(),
      const Scaffold(body: SearchPage()),
      const Scaffold(body: PeoplePage()),
      const ReviewPage(),
      const NightPage(),
      const OnboardingPage(),
      const Scaffold(body: SettingsPage()),
      const PermissionsPage(),
      const ClustersPage(),
      const WhoPage(id: 1),
    ]) {
      await t.pumpWidget(big(w));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
    }
    await cleanup(t);
  });

  testWidgets('어두운 화면에서도 홈이 그려진다', (t) async {
    t.view.physicalSize = const Size(390, 844) * 3;
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(MaterialApp(theme: buildTheme(const Color(0xFF0F766E), Brightness.dark), home: const Shell()));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('추억'), findsOneWidget);
    await cleanup(t);
  });
}
