// 화면마다 가짜 데이터로 그려 보아 레이아웃 오류(넘침·크기 없는 목록 등)가 없는지 본다. 폰 없이 PC에서 돈다.
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

Future<Object?> fake(MethodCall call) async {
  switch (call.method) {
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
