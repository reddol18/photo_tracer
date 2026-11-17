// 화면마다 가짜 데이터로 그려 보아 레이아웃 오류(넘침·크기 없는 목록 등)가 없는지 본다. 폰 없이 PC에서 돈다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
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
Map<String, dynamic> lastPicks = {}; // 마지막 'search'의 picks
Map<String, dynamic> lastSearch = {}; // 마지막 'search'의 인자(기간 from/to 포함)
Map<String, dynamic> lastMoments = {}; // 마지막 'moments'의 인자
final periodCalls = <Map<String, dynamic>>[]; // 'period'(기간 시트 → Kotlin When.sheet)로 받은 것
final prefSets = <Map<String, dynamic>>[]; // 'setPref'로 받은 {key, value}
Map<String, dynamic> lastMonthIndex = {}; // 마지막 'monthIndex'의 인자(#19)
final momentCalls = <Map<String, dynamic>>[]; // 'moments'로 받은 인자들

/// 빠른 이동 막대(#19)용 가짜 목록: 해마다 달마다 [per]개씩, 최근 순. 날짜만 있는 가짜 순간
List<Map<String, dynamic>> fakeYears(Map<int, List<int>> ym, {int per = 3}) {
  var id = 5000;
  return [
    for (final y in (ym.keys.toList()..sort((a, b) => b - a)))
      for (final m in (ym[y]!.toList()..sort((a, b) => b - a)))
        for (var i = 0; i < per; i++)
          {'id': id++, 'start': DateTime(y, m, 20 - i * 5, 12).millisecondsSinceEpoch, 'end': DateTime(y, m, 20 - i * 5, 14).millisecondsSinceEpoch,
           'n': 2, 'covers': <int>[], 'people': <int>[]},
  ];
}

/// scenario['all']을 기간(from/to)으로 거른 목록. Kotlin과 같이 최근 순
List<Map<String, dynamic>> allMoments(Map<String, dynamic> a) {
  final all = (scenario['all'] as List).cast<Map<String, dynamic>>();
  final from = a['from'] as int?, to = a['to'] as int?;
  return [for (final m in all) if ((from == null || (m['end'] as int) >= from) && (to == null || (m['start'] as int) <= to)) m];
}

/// Kotlin MonthIndex.of와 같은 규칙(달마다 첫 위치와 개수)
List<Map<String, int>> monthIndexOf(List<Map<String, dynamic>> list) {
  final out = <Map<String, int>>[];
  for (var i = 0; i < list.length; i++) {
    final d = DateTime.fromMillisecondsSinceEpoch(list[i]['start'] as int);
    if (out.isEmpty || out.last['year'] != d.year || out.last['month'] != d.month) {
      out.add({'year': d.year, 'month': d.month, 'offset': i, 'n': 0});
    }
    out.last['n'] = out.last['n']! + 1;
  }
  return out;
}

/// 'period'의 가짜: 달은 그대로 기간으로, 나이는 연 나이(Kotlin When.Age 규칙을 흉내 — 규칙 자체는 Kotlin SpanTest가 본다)
Map<String, dynamic> fakePeriod(Map<String, dynamic> a) {
  int from(int y, int m) => DateTime(y, m).millisecondsSinceEpoch;
  if (a['kind'] == 'age') {
    final birth = a['birth'] as int, x = a['a']['n'] as int, z = a['b']['n'] as int;
    final y1 = birth + x, y2 = birth + z;
    return {'from': from(y1, 1), 'to': from(y2 + 1, 1) - 1, 'range': y1 == y2 ? '$y1년' : '$y1~$y2년',
            'age': x == z ? '$x살' : '$x~$z살'};
  }
  final y1 = a['y1'] as int, m1 = a['m1'] as int, y2 = a['y2'] as int, m2 = a['m2'] as int;
  return {'from': from(y1, m1), 'to': from(y2, m2 + 1) - 1,
          'range': y1 == y2 && m1 == 1 && m2 == 12 ? '$y1년' : '$y1.$m1~$y2.$m2'};
}

Future<Object?> fake(MethodCall call) async {
  switch (call.method) {
    case 'yearCounts':
      return [{'year': 2025, 'n': 1204}, {'year': 2023, 'n': 840}, {'year': 2019, 'n': 12}];
    case 'period':
      final a = Map<String, dynamic>.from(call.arguments as Map);
      periodCalls.add(a);
      return fakePeriod(a);
    case 'thumb':
      thumbSizes.putIfAbsent((call.arguments['id'] as num).toInt(), () => []).add(call.arguments['size'] as int);
      return scenario['thumb']; // 기본은 그림 없음 → 빈 칸으로 그린다
    case 'pref':
      return scenario['pref.${call.arguments['key']}'];
    case 'setPref':
      prefSets.add(Map<String, dynamic>.from(call.arguments as Map));
      return null;
    case 'photo':
      return scenario['photo']; // 크게 보기 사진(기본은 그림 없음 → 도는 표시)
    case 'status':
      return scenario['status'] ?? status();
    case 'runs':
      return [
        {'id': 1, 'mode': 'night', 'start': day, 'end': day + 5 * 3600000, 'last': day + 5 * 3600000, 'photos': 1240, 'faces': 900,
         'vectors': 300, 'face_ms': 1200.0, 'vec_ms': 900.0, 'rests': 2, 'max_temp': 41.5, 'stop': '충전 끊김', 'note': 'FGS'},
      ];
    case 'people':
      return people;
    case 'monthIndex':
      lastMonthIndex = Map<String, dynamic>.from(call.arguments as Map);
      if (scenario['all'] == null) return null; // 기본: 목차 없음 → 막대 숨김
      return monthIndexOf(allMoments(lastMonthIndex));
    case 'moments':
      lastMoments = Map<String, dynamic>.from(call.arguments as Map);
      momentCalls.add(lastMoments);
      if (scenario['delay'] != null) await Future<void>.delayed(scenario['delay'] as Duration); // 폰처럼 답이 늦게
      if (scenario['all'] != null) {
        final all = allMoments(lastMoments);
        final o = call.arguments['offset'] as int, l = call.arguments['limit'] as int;
        return all.sublist(o.clamp(0, all.length), (o + l).clamp(0, all.length));
      }
      if (scenario['noMomentsInRange'] == true && call.arguments['from'] != null) return [];
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
      lastSearch = Map<String, dynamic>.from(call.arguments as Map);
      lastPicks = Map<String, dynamic>.from(call.arguments['picks'] as Map? ?? {});
      if (scenario['dynamicSearch'] == true) {
        // 검색어 낱말 중 등록 이름(조사 '과'·'와'·'의'를 떼고)은 인물 낱말, 나머지는 장면.
        // 시기 말(#16): '작년' → 2025년, '1살 때' → 누구 나이인지 묻기(골랐으면 딸 생년으로)
        final ws = <Map<String, dynamic>>[];
        final rest = <String>[];
        Map<String, dynamic>? when;
        final toks = q.split(' ');
        if (toks.contains('작년')) {
          when = {'words': ['작년'], 'text': '작년', 'range': '2025년'};
        } else if (toks.contains('1살')) {
          final picked = lastPicks['@나이'] as List?;
          when = picked == null
              ? {'words': ['1살', '때'], 'text': '1살 때', 'age': '1살', 'who': null, 'need': 'owner', 'cands': [1, 3]}
              : {'words': ['1살', '때'], 'text': '1살 때', 'age': '1살', 'who': '딸', 'range': '2019년'};
        }
        for (final tok in toks.where((t) => !((when?['words'] as List?)?.contains(t) ?? false))) {
          final f = tok.replaceAll(RegExp(r'(과|와|의)$'), '');
          final p = people.where((p) => (p['name'] as String).replaceAll(' ', '') == f).firstOrNull;
          if (p == null) {
            rest.add(tok);
          } else {
            ws.add({'word': f, 'chosen': [p['id']], 'cands': [{'ids': [p['id']], 'note': ''}]});
          }
        }
        return {'items': [{'kind': 'photo', 'cover': 102, 'date': day}], 'rest': rest.join(' '),
                'who': ws.isEmpty ? null : ws.map((w) => w['word']).join(' · '), 'photos': 1, 'words': ws, 'hint': false,
                'when': call.arguments['from'] != null ? null : when}; // 시트 기간이 오면 Kotlin은 시기 칩을 주지 않는다(#17)
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
    periodCalls.clear();
    prefSets.clear();
    ShowFaces.on.value = true;
    lastSearch = {};
    lastMoments = {};
    lastMonthIndex = {};
    momentCalls.clear();
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

  testWidgets('권한과 배터리: 제조사 안내 카드와 설정 열기 (#18)', (t) async {
    final opened = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openVendorSettings') opened.add(call.arguments);
      return fake(call);
    });
    // 샤오미(Redmi): 자동 시작 화면을 넘긴다
    scenario['status'] = {...status(), 'manufacturer': 'Xiaomi', 'brand': 'Redmi'};
    await t.runAsync(() => Status.i.refresh());
    await show(t, const PermissionsPage());
    expect(find.text('샤오미 폰: 자동 시작 켜기'), findsOneWidget);
    await t.tap(find.text('자동 시작 설정 열기'));
    await t.pump();
    expect(opened.last, {
      'screens': [['com.miui.securitycenter', 'com.miui.permcenter.autostart.AutoStartManagementActivity']],
    });
    // 목록에 없는 폰(픽셀): 기본 안내, 넘기는 화면 없음 → 앱 정보
    scenario['status'] = {...status(), 'manufacturer': 'Google', 'brand': 'google'};
    await t.runAsync(() => Status.i.refresh());
    await t.pump();
    expect(find.text('이 폰: 앱 정보에서 배터리 제한 풀기'), findsOneWidget);
    await t.tap(find.text('앱 정보 열기'));
    await t.pump();
    expect(opened.last, {'screens': []});
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

  Future<void> type(WidgetTester t, String q) async {
    await t.enterText(find.byType(TextField), q);
    await t.testTextInput.receiveAction(TextInputAction.search);
    await settle(t);
  }

  testWidgets('검색: 시기 칩(#16)이 보이고 ✕로 시기 말만 빼고 다시 검색', (t) async {
    scenario['dynamicSearch'] = true;
    await show(t, const Scaffold(body: SearchPage()));
    await type(t, '딸 작년 바다');
    expect(searches.last, '딸 작년 바다');
    expect(find.text('작년: 2025년'), findsOneWidget);
    expect(find.text('장면: 바다'), findsOneWidget);
    await t.tap(find.byTooltip('작년 빼기'));
    await settle(t);
    expect(searches.last, '딸 바다');
    expect(find.byKey(const ValueKey('period-chip')), findsNothing);
    expect(find.byTooltip('딸 빼기'), findsOneWidget); // 인물 칩은 그대로
    // 시기만 있는 검색: 인물 칩이 없어도 '이렇게 이해했어요'에 시기 칩
    await type(t, '작년');
    expect(find.text('이렇게 이해했어요'), findsOneWidget);
    expect(find.text('작년: 2025년'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('검색: 나이 말에 인물이 없으면 칩에서 누구 나이인지 고른다(#16)', (t) async {
    scenario['dynamicSearch'] = true;
    await show(t, const Scaffold(body: SearchPage()));
    await type(t, '1살 때');
    expect(find.text('1살 때: 누구 나이인가요?'), findsOneWidget);
    await t.tap(find.text('1살 때: 누구 나이인가요?'));
    await t.pumpAndSettle();
    expect(find.text('2018년생'), findsOneWidget); // 생년 있는 인물(엄마·딸) 중에서
    await t.tap(find.text('2018년생'));
    await settle(t);
    expect(searches.last, '1살 때'); // 검색어는 그대로, 고른 인물은 picks로
    expect(lastPicks['@나이'], [3]);
    expect(find.text('딸 1살 때: 2019년'), findsOneWidget);
    final n = searches.length;
    await t.tap(find.byTooltip('1살 때 빼기')); // 시기 말뿐이라 빼면 처음 화면
    await settle(t);
    expect(searches.length, n);
    expect(find.text('인물로 찾기'), findsOneWidget);
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

  // ───── 기간 거르기(#17)
  Future<void> anim(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pickYear(WidgetTester t, int y) async {
    await anim(t);
    expect(find.text('기간으로 거르기'), findsOneWidget);
    await t.tap(find.byKey(ValueKey('year-$y')));
    await anim(t);
    await t.tap(find.text('$y년 보기'));
    await anim(t);
  }

  testWidgets('홈: 기간 칩 → 시트에서 연도 → 칩이 "2023년"으로, 인물과 함께, ✕로 풀기 (#17)', (t) async {
    await show(t, const Shell());
    expect(find.text('기간'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('home-period-chip')));
    await anim(t);
    expect(find.text('1,204장'), findsOneWidget); // 사진이 있는 해와 사진 수
    expect(find.text('인물 나이'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('year-2023')));
    await anim(t);
    await t.tap(find.text('2023년 보기'));
    await anim(t);
    expect(find.text('기간으로 거르기'), findsNothing);
    expect(find.text('2023년'), findsOneWidget);
    expect(find.text('기간'), findsNothing);
    expect(lastMoments['from'], DateTime(2023).millisecondsSinceEpoch);
    expect(lastMoments['to'], DateTime(2024).millisecondsSinceEpoch - 1);
    await t.tap(find.text('딸').first); // 인물 거르기와 함께
    await settle(t);
    expect(lastMoments['person'], 3);
    expect(lastMoments['from'], DateTime(2023).millisecondsSinceEpoch);
    // 다시 열면 고른 해가 그대로
    await t.tap(find.text('2023년'));
    await anim(t);
    expect(find.text('2023년 보기'), findsOneWidget);
    await t.tap(find.text('풀기')); // 시트의 '풀기'
    await anim(t);
    expect(find.text('기간'), findsOneWidget);
    expect(lastMoments['from'], isNull);
    expect(lastMoments['person'], 3);
    // 칩의 ✕
    await t.tap(find.byKey(const ValueKey('home-period-chip')));
    await pickYear(t, 2025);
    expect(find.text('2025년'), findsOneWidget);
    await t.tap(find.byTooltip('기간 풀기'));
    await settle(t);
    expect(find.text('기간'), findsOneWidget);
    expect(lastMoments['from'], isNull);
    await cleanup(t);
  });

  testWidgets('홈: 기간에 맞는 순간이 없으면 빈 화면과 풀기 (#17)', (t) async {
    scenario['noMomentsInRange'] = true;
    await show(t, const Shell());
    await t.tap(find.byKey(const ValueKey('home-period-chip')));
    await pickYear(t, 2019);
    expect(find.text('맞는 순간이 없어요'), findsOneWidget);
    expect(find.textContaining('사진 48장'), findsNothing);
    await t.tap(find.text('기간 풀기'));
    await settle(t);
    expect(find.text('맞는 순간이 없어요'), findsNothing);
    expect(find.textContaining('사진 48장'), findsOneWidget);
    await cleanup(t);
  });

  // ───── 빠른 이동 막대(#19)
  // 2025년 10~1월, 2023년 12~7월, 2019년 5~4월, 달마다 3개 = 54개(한 번에 40개씩 불러온다)
  Map<int, List<int>> threeYears() => {2025: [10, 9, 8, 7, 6, 5, 4, 3, 2, 1], 2023: [12, 11, 10, 9, 8, 7], 2019: [5, 4]};
  final bar = find.byKey(const ValueKey('year-bar'));

  bool onScreen(WidgetTester t, Finder f) {
    if (f.evaluate().isEmpty) return false;
    final r = t.getRect(f);
    return r.top >= 0 && r.bottom <= t.view.physicalSize.height / t.view.devicePixelRatio;
  }

  testWidgets('홈 빠른 이동: 해가 둘 이상이면 막대, 하나뿐이거나 목록이 짧으면 숨김 (#19)', (t) async {
    // 목차가 없으면(기본 가짜) 막대 없음
    await show(t, const Shell());
    expect(bar, findsNothing);
    await cleanup(t);
    // 해 셋
    scenario['all'] = fakeYears(threeYears());
    await show(t, const Shell());
    expect(bar, findsOneWidget);
    for (final y in ["'25", "'23", "'19"]) {
      expect(find.text(y), findsOneWidget);
    }
    expect(t.getSize(bar).width, greaterThanOrEqualTo(44)); // 터치 영역
    expect(lastMonthIndex.containsKey('person'), isTrue); // 목록과 같은 거르기 조건으로 묻는다
    await cleanup(t);
    // 해 하나
    scenario['all'] = fakeYears({2025: [10, 9, 8, 7, 6, 5]});
    await show(t, const Shell());
    expect(bar, findsNothing);
    await cleanup(t);
    // 해는 둘이지만 순간이 몇 개뿐(한 화면 안팎)
    scenario['all'] = fakeYears({2025: [10], 2023: [5]}, per: 2);
    await show(t, const Shell());
    expect(bar, findsNothing);
    await cleanup(t);
  });

  testWidgets('홈 빠른 이동: 해를 누르면 그 자리부터 불러와 그해 첫 달 머리글로, 위로 가면 앞쪽을 불러온다 (#19)', (t) async {
    scenario['all'] = fakeYears(threeYears());
    await show(t, const Shell());
    expect(find.text('2025년 10월'), findsOneWidget);
    expect(find.text('2019년 5월'), findsNothing); // 아직 안 불러옴(40개까지)
    await t.tap(find.byKey(const ValueKey('bar-year-2019')));
    await settle(t);
    await settle(t);
    expect(momentCalls.last['offset'], 48); // 2019년 5월은 49번째부터: 그 자리부터 불러온다
    expect(onScreen(t, find.text('2019년 5월')), isTrue);
    expect(find.text('2025년 10월'), findsNothing);
    // 머리글이 맨 위 근처(제목에 가리지 않고)
    expect(t.getRect(find.text('2019년 5월')).top, lessThan(80));
    // 위로 끌어 올라가면 앞쪽(8~47번째)을 불러와 이어 붙인다
    await t.drag(find.text('2019년 5월'), const Offset(0, 300));
    await settle(t);
    expect(momentCalls.any((c) => c['offset'] == 8 && c['limit'] == 40), isTrue);
    expect(find.text('2023년 7월'), findsOneWidget);
    expect(onScreen(t, find.text('2019년 5월')), isTrue); // 앞쪽이 붙어도 보던 자리는 그대로
    // 이미 불러온 곳으로 뛰면 다시 부르지 않는다
    final n = momentCalls.length;
    await t.tap(find.byKey(const ValueKey('bar-year-2023')));
    await settle(t);
    expect(momentCalls.length, n);
    expect(onScreen(t, find.text('2023년 12월')), isTrue);
    await t.pump(const Duration(seconds: 2)); // 흐려지는 타이머
    await cleanup(t);
  });

  testWidgets('홈 빠른 이동: 끄는 동안 "연월" 말풍선, 놓으면 사라지고 막대는 잠시 뒤 흐려진다 (#19)', (t) async {
    scenario['all'] = fakeYears(threeYears());
    await show(t, const Shell());
    final opacity = find.ancestor(of: bar, matching: find.byType(AnimatedOpacity));
    expect(t.widget<AnimatedOpacity>(opacity).opacity, lessThan(1)); // 평소엔 흐리게
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('bar-year-2023'))));
    await g.moveBy(const Offset(0, 20));
    await g.moveBy(const Offset(0, 10));
    await settle(t);
    expect(find.byKey(const ValueKey('year-bubble')), findsOneWidget);
    final label = t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('year-bubble')), matching: find.byType(Text))).data!;
    expect(label, matches(RegExp(r'^2023년 \d{1,2}월$')));
    expect(t.widget<AnimatedOpacity>(opacity).opacity, 1);
    expect(onScreen(t, find.widgetWithText(SectionLabel, label)), isTrue); // 그 달 머리글로 뛰었다
    await g.up();
    await settle(t);
    expect(find.byKey(const ValueKey('year-bubble')), findsNothing);
    await t.pump(const Duration(seconds: 2));
    expect(t.widget<AnimatedOpacity>(opacity).opacity, lessThan(1));
    await cleanup(t);
  });

  testWidgets('홈 빠른 이동: 기간으로 거르면 그 기간 안의 해만 (#19)', (t) async {
    scenario['all'] = fakeYears(threeYears());
    await show(t, const Shell());
    await t.tap(find.byKey(const ValueKey('home-period-chip')));
    await anim(t);
    await t.tap(find.text('인물 나이'));
    await anim(t);
    await t.tap(find.byKey(const ValueKey('age-who-3')));
    await t.tap(find.byKey(const ValueKey('age-1살')));
    await t.ensureVisible(find.byKey(const ValueKey('age-5살')));
    await t.tap(find.byKey(const ValueKey('age-5살')));
    await anim(t);
    await t.tap(find.text('딸 1~5살 보기')); // 2019~2023년
    await anim(t);
    expect(lastMonthIndex['from'], DateTime(2019).millisecondsSinceEpoch);
    expect(bar, findsOneWidget);
    expect(find.text("'23"), findsOneWidget);
    expect(find.text("'19"), findsOneWidget);
    expect(find.text("'25"), findsNothing);
    await cleanup(t);
  });

  testWidgets('홈 빠른 이동: 좁은 화면 + 큰 글씨에서 막대와 카드가 겹치지 않는다, TalkBack "연도로 이동" (#19)', (t) async {
    scenario['all'] = fakeYears(threeYears());
    final sem = t.ensureSemantics();
    t.view.physicalSize = const Size(320, 640) * 3;
    t.view.devicePixelRatio = 3;
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(const Color(0xFF2563EB), Brightness.light),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
      home: const Shell(),
    ));
    await settle(t);
    expect(t.takeException(), isNull);
    final barRect = t.getRect(bar);
    final cards = find.descendant(of: find.byType(MomentCard), matching: find.byType(Card));
    expect(cards, findsWidgets);
    for (final e in cards.evaluate()) {
      final r = t.getRect(find.byWidget(e.widget));
      expect(r.right, lessThanOrEqualTo(barRect.left), reason: '카드 오른쪽 $r / 막대 $barRect');
    }
    // 막대는 제목·칩 줄 아래에서 시작(검색 버튼·칩을 가리지 않는다)
    expect(barRect.top, greaterThanOrEqualTo(t.getRect(find.widgetWithIcon(IconButton, Icons.search)).bottom));
    // TalkBack: "연도로 이동" 묶음 안에 해마다 버튼
    expect(find.bySemanticsLabel('연도로 이동'), findsOneWidget);
    expect(t.getSemantics(find.bySemanticsLabel('2019년')), isSemantics(label: '2019년', isButton: true, hasTapAction: true));
    expect(t.getSemantics(find.bySemanticsLabel('2025년')), isSemantics(isSelected: true)); // 지금 보는 해
    final node = t.getSemantics(find.bySemanticsLabel('2019년'));
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await settle(t);
    await settle(t);
    expect(onScreen(t, find.text('2019년 5월')), isTrue);
    await t.pump(const Duration(seconds: 2));
    sem.dispose();
    await cleanup(t);
  });

  // 폰에서 본 배치(#19 확인): 360×820dp, 상태 막대 34dp, 아래 탐색 막대. 해 아홉(빈 해 있음), 달마다 3개
  Map<int, List<int>> nineYears() => {
        for (final y in [2026, 2025, 2024, 2023, 2022, 2021, 2020, 2016, 2014]) y: [for (var m = 12; m >= 1; m--) m],
      };

  Future<void> phone(WidgetTester t) async {
    t.view.physicalSize = const Size(720, 1640);
    t.view.devicePixelRatio = 2;
    t.view.padding = const FakeViewPadding(top: 68, bottom: 96);
    await t.pumpWidget(MaterialApp(theme: buildTheme(const Color(0xFF2563EB), Brightness.light), home: const Shell()));
    await settle(t);
  }

  /// 목록 맨 위(막대 윗변 근처)에 보이는 월 머리글
  String topHeader(WidgetTester t) {
    final top = t.getRect(bar).top;
    final hs = find.byType(SectionLabel).evaluate().map((e) => (t.getRect(find.byWidget(e.widget)), (e.widget as SectionLabel).text)).toList()
      ..sort((a, b) => a.$1.top.compareTo(b.$1.top));
    return hs.where((h) => h.$1.bottom > top + 1).first.$2;
  }

  testWidgets('홈 빠른 이동(폰 배치): 한 번 뛰어 막대가 늘어난 뒤에도 누른 해로 간다 (#19)', (t) async {
    scenario['all'] = fakeYears(nineYears());
    scenario['delay'] = const Duration(milliseconds: 80);
    await phone(t);
    final firstTop = t.getRect(bar).top;
    await t.tap(find.byKey(const ValueKey('bar-year-2020')));
    await settle(t);
    await settle(t);
    expect(topHeader(t), '2020년 12월');
    expect(t.getRect(bar).top, lessThan(firstTop)); // 제목·칩이 사라져 막대가 위로 늘었다
    for (final y in [2020, 2023, 2016, 2021, 2014, 2025, 2025]) {
      await t.tap(find.byKey(ValueKey('bar-year-$y')));
      await settle(t);
      await settle(t);
      expect(topHeader(t), '$y년 12월', reason: "'$y 누름");
    }
    // 막대는 아래 탭 막대 위에서 끝난다
    expect(t.getRect(bar).bottom, lessThanOrEqualTo(t.getRect(find.byType(NavigationBar)).top));
    await t.pump(const Duration(seconds: 2));
    await cleanup(t);
    t.view.resetPadding();
  });

  testWidgets('홈 빠른 이동(폰 배치): 실제 끌기 — 말풍선·또렷함, 놓은 해가 손가락 아래 해 (#19)', (t) async {
    scenario['all'] = fakeYears(nineYears());
    scenario['delay'] = const Duration(milliseconds: 80);
    await phone(t);
    await t.tap(find.byKey(const ValueKey('bar-year-2021')));
    await settle(t);
    await settle(t);
    final opacity = find.ancestor(of: bar, matching: find.byType(AnimatedOpacity));
    final from = t.getCenter(find.byKey(const ValueKey('bar-year-2020')));
    final to = t.getCenter(find.byKey(const ValueKey('bar-year-2024')));
    final g = await t.startGesture(from);
    for (var i = 1; i <= 24; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 24)!);
      await t.pump(const Duration(milliseconds: 30));
    }
    await settle(t);
    expect(find.byKey(const ValueKey('year-bubble')), findsOneWidget);
    expect(t.widget<AnimatedOpacity>(opacity).opacity, 1);
    final label = t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('year-bubble')), matching: find.byType(Text))).data!;
    expect(label, startsWith('2024년 '));
    // 막대 배치가 끄는 동안 바뀌지 않아 손가락 아래 칸이 그대로 '24
    expect(t.getRect(find.byKey(const ValueKey('bar-year-2024'))).contains(to), isTrue);
    expect(topHeader(t), label);
    await t.pump(const Duration(seconds: 3)); // 붙잡고 있는 동안에도 그대로
    expect(find.byKey(const ValueKey('year-bubble')), findsOneWidget);
    expect(t.widget<AnimatedOpacity>(opacity).opacity, 1);
    await g.up();
    await settle(t);
    expect(find.byKey(const ValueKey('year-bubble')), findsNothing);
    expect(topHeader(t), label);
    await t.pump(const Duration(seconds: 2));
    await cleanup(t);
    t.view.resetPadding();
  });

  testWidgets('홈 빠른 이동: 먼 해로 뛰는 동안 목록이 비지 않는다 (#19)', (t) async {
    scenario['all'] = fakeYears(nineYears());
    // 'moments' 답을 늦춘다: 그사이 화면에 앞 목록이나 머리글이 있어야 한다
    final gate = <Completer<void>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'moments' && scenario['slow'] == true) {
        final c = Completer<void>();
        gate.add(c);
        await c.future;
      }
      return fake(call);
    });
    await phone(t);
    scenario['slow'] = true;
    await t.tap(find.byKey(const ValueKey('bar-year-2016')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(gate, isNotEmpty);
    expect(find.byType(SectionLabel), findsWidgets); // 비지 않았다
    expect(find.byType(MomentCard), findsWidgets);
    scenario['slow'] = false;
    for (final c in gate) {
      c.complete();
    }
    await settle(t);
    await settle(t);
    expect(topHeader(t), '2016년 12월');
    await t.pump(const Duration(seconds: 2));
    await cleanup(t);
    t.view.resetPadding();
  });

  testWidgets('홈: 기간 시트 나이 탭 — 두 나이 사이 범위와 미리보기, 직접 고르기 (#17)', (t) async {
    await show(t, const Shell());
    await t.tap(find.byKey(const ValueKey('home-period-chip')));
    await anim(t);
    await t.tap(find.text('인물 나이'));
    await anim(t);
    expect(find.text('누구 나이로?'), findsOneWidget);
    expect(find.byKey(const ValueKey('age-who-2')), findsNothing); // 생년 없는 인물은 안 나온다
    await t.tap(find.byKey(const ValueKey('age-who-3')));
    await t.tap(find.byKey(const ValueKey('age-1살')));
    await t.tap(find.byKey(const ValueKey('age-2살')));
    await anim(t);
    expect(periodCalls.last, {'kind': 'age', 'birth': 2018, 'a': {'kind': '살', 'n': 1}, 'b': {'kind': '살', 'n': 2}});
    expect(find.text('딸 1~2살 → 2019년 1월 ~ 2020년 12월'), findsOneWidget);
    await t.tap(find.text('딸 1~2살 보기'));
    await anim(t);
    expect(find.text('딸 1~2살'), findsOneWidget);
    expect(lastMoments['from'], DateTime(2019).millisecondsSinceEpoch);
    await cleanup(t);
  });

  testWidgets('홈: 생년 있는 인물이 없으면 나이 탭에 안내 (#17)', (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'people') return [for (final p in people) {...p, 'birth_year': null}];
      return fake(call);
    });
    await show(t, const Shell());
    await t.tap(find.byKey(const ValueKey('home-period-chip')));
    await anim(t);
    await t.tap(find.text('인물 나이'));
    await anim(t);
    expect(find.text('인물에 생년을 넣으면 나이로 거를 수 있어요.'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('검색: 결과 화면 "+ 기간" → 고르면 시기 칩 하나, 인물 빼도 남고 ✕로 풀기 (#17)', (t) async {
    scenario['dynamicSearch'] = true;
    await show(t, const Scaffold(body: SearchPage()));
    await type(t, '딸 바다');
    expect(find.byKey(const ValueKey('add-period-chip')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('add-period-chip')));
    await pickYear(t, 2025);
    expect(searches.last, '딸 바다');
    expect(lastSearch['from'], DateTime(2025).millisecondsSinceEpoch);
    expect(find.byKey(const ValueKey('period-chip')), findsOneWidget);
    expect(find.text('2025년'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-period-chip')), findsNothing);
    await t.tap(find.byTooltip('딸 빼기')); // 인물을 빼도 기간은 그대로
    await settle(t);
    expect(searches.last, '바다');
    expect(lastSearch['from'], DateTime(2025).millisecondsSinceEpoch);
    expect(find.text('2025년'), findsOneWidget);
    await t.tap(find.byTooltip('2025년 빼기'));
    await settle(t);
    expect(searches.last, '바다');
    expect(lastSearch['from'], isNull);
    expect(find.byKey(const ValueKey('add-period-chip')), findsOneWidget);
    // 새 검색어를 치면 시트 기간은 풀린다
    await t.tap(find.byKey(const ValueKey('add-period-chip')));
    await pickYear(t, 2023);
    expect(lastSearch['from'], isNotNull);
    await type(t, '캠핑');
    expect(lastSearch['from'], isNull);
    await cleanup(t);
  });

  testWidgets('검색: 검색어 시기(#16) 칩을 눌러 시트에서 고르면 시기 말을 지우고 칩 하나로 (#17)', (t) async {
    scenario['dynamicSearch'] = true;
    await show(t, const Scaffold(body: SearchPage()));
    await type(t, '딸 작년 바다');
    expect(find.text('작년: 2025년'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-period-chip')), findsNothing); // 기간이 있으면 '+ 기간' 없음
    await t.tap(find.text('작년: 2025년'));
    await pickYear(t, 2023);
    expect(searches.last, '딸 바다'); // 검색어 속 '작년'은 지우고
    expect(lastSearch['from'], DateTime(2023).millisecondsSinceEpoch); // 고른 기간으로
    expect(find.text('작년: 2025년'), findsNothing);
    expect(find.byKey(const ValueKey('period-chip')), findsOneWidget);
    expect(find.text('2023년'), findsOneWidget);
    // 시기 말뿐인 검색어: 시트로 바꾸면 검색어 없이 기간만으로, ✕면 처음 화면
    await type(t, '작년');
    await t.tap(find.text('작년: 2025년'));
    await pickYear(t, 2019);
    expect(searches.last, '');
    expect(lastSearch['from'], DateTime(2019).millisecondsSinceEpoch);
    expect(find.text('2019년'), findsOneWidget);
    final n = searches.length;
    await t.tap(find.byTooltip('2019년 빼기'));
    await settle(t);
    expect(searches.length, n);
    expect(find.text('인물로 찾기'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('검색: 나이 말 칩을 누르면 나이 탭으로, 읽은 인물·나이가 골라져 있다 (#17)', (t) async {
    scenario['dynamicSearch'] = true;
    await show(t, const Scaffold(body: SearchPage()));
    await type(t, '1살 때');
    await t.tap(find.text('1살 때: 누구 나이인가요?'));
    await t.pumpAndSettle();
    await t.tap(find.text('2018년생'));
    await settle(t);
    await t.tap(find.text('딸 1살 때: 2019년'));
    await anim(t);
    expect(find.text('누구 나이로?'), findsOneWidget);
    expect(find.text('딸 1살 → 2019년 1월 ~ 2019년 12월'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('age-3살')));
    await anim(t);
    await t.tap(find.text('딸 1~3살 보기'));
    await anim(t);
    expect(searches.last, ''); // '1살 때'는 지웠다
    expect(lastPicks.containsKey('@나이'), isFalse);
    expect(find.text('딸 1~3살: 2019~2021년'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('기간: 좁은 화면(360) + 큰 글씨(1.3배)에서 홈 칩 줄·시트·검색 칩이 넘치지 않는다 (#17)', (t) async {
    scenario['dynamicSearch'] = true;
    t.view.physicalSize = const Size(360, 700) * 3;
    t.view.devicePixelRatio = 3;
    Widget big(Widget w) => MaterialApp(
          theme: buildTheme(const Color(0xFF2563EB), Brightness.light),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
          home: w,
        );
    await t.pumpWidget(big(const Shell()));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('home-period-chip')));
    await anim(t);
    await t.tap(find.byKey(const ValueKey('year-2023')));
    await anim(t);
    await t.tap(find.text('인물 나이'));
    await anim(t);
    await t.tap(find.byKey(const ValueKey('age-who-3')));
    await t.tap(find.byKey(const ValueKey('age-백일')));
    await t.tap(find.byKey(const ValueKey('age-3살')));
    await anim(t);
    await t.tap(find.byKey(const ValueKey('period-apply')));
    await anim(t);
    expect(find.byTooltip('기간 풀기'), findsOneWidget);
    final x = t.getRect(find.byTooltip('기간 풀기'));
    expect(x.height, greaterThanOrEqualTo(40));
    expect(x.width, greaterThanOrEqualTo(40));
    await t.pumpWidget(big(const Scaffold(body: SearchPage())));
    await settle(t);
    await type(t, '딸과 아주긴이름의할아버지 바다');
    expect(find.byKey(const ValueKey('add-period-chip')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('add-period-chip')));
    await pickYear(t, 2023);
    expect(find.byKey(const ValueKey('period-chip')), findsOneWidget);
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

  // ───── 크게 보기: 얼굴 박스 켜고 끄기(#11) · 확대와 넘기기(#12)
  bool boxesShown() =>
      find.byWidgetPredicate((w) => w is CustomPaint && w.painter?.runtimeType.toString() == '_FaceBoxes').evaluate().isNotEmpty;

  // '얼굴 박스' 토글의 켜짐: Semantics toggled와 체크 아이콘이 서로 맞아야 한다
  bool toggleOn(WidgetTester t) {
    final sem = t.widget<Semantics>(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '얼굴 박스'));
    final check = find.descendant(of: find.byType(OutlinedButton), matching: find.byIcon(Icons.check)).evaluate().isNotEmpty;
    expect(sem.properties.toggled, check);
    expect(sem.properties.button, isTrue);
    return check;
  }

  Future<void> photoLoad(WidgetTester t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // 그림 풀기
    await t.pump();
    await t.pump();
  }

  testWidgets('크게 보기: 얼굴 박스 끄기는 다른 사진·다시 연 화면·재시작 후에도 그대로 (#11)', (t) async {
    // 8x4 PNG. 다른 시험과 사진 캐시가 겹치지 않게 처음 쓰는 id로
    scenario['photo'] = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXYxhwwMAAAACEAAHOfCFIAAAAAElFTkSuQmCC');
    await show(t, Scaffold(
      body: Builder(builder: (context) => Column(children: [
            TextButton(onPressed: () => showPhoto(context, 7901), child: const Text('사진 A')),
            TextButton(onPressed: () => showPhoto(context, 7902), child: const Text('사진 B')),
          ])),
    ));
    await t.tap(find.text('사진 A'));
    await anim(t);
    await photoLoad(t);
    expect(boxesShown(), isTrue);
    expect(toggleOn(t), isTrue);
    expect(find.textContaining('얼굴을 눌러 고칠 수 있어요'), findsOneWidget);
    await t.tap(find.text('얼굴 박스'));
    await t.pump();
    expect(boxesShown(), isFalse);
    expect(toggleOn(t), isFalse);
    expect(find.text('얼굴 박스'), findsOneWidget); // 글자는 켜짐·꺼짐 모두 같다
    expect(prefSets.last, {'key': 'faces', 'value': '0'});
    expect(find.textContaining('얼굴 박스를 켜면 고칠 수 있어요'), findsOneWidget); // 꺼진 상태임을 아래 글로
    // 화면을 닫고 다른 사진을 열어도 숨긴 채로
    await t.pageBack();
    await anim(t);
    await t.tap(find.text('사진 B'));
    await anim(t);
    await photoLoad(t);
    expect(boxesShown(), isFalse);
    expect(toggleOn(t), isFalse);
    expect(find.textContaining('얼굴 박스를 켜면 고칠 수 있어요'), findsOneWidget);
    // 앱을 다시 켜면 pref에서 읽는다
    ShowFaces.on.value = true;
    scenario['pref.faces'] = '0';
    await t.runAsync(() => ShowFaces.load());
    expect(ShowFaces.on.value, isFalse);
    await t.pump();
    // 다시 보기 → 보이고 저장
    await t.tap(find.text('얼굴 박스'));
    await t.pump();
    expect(boxesShown(), isTrue);
    expect(toggleOn(t), isTrue);
    expect(prefSets.last, {'key': 'faces', 'value': '1'});
    await cleanup(t);
  });

  testWidgets('크게 보기: 확대 중·두 손가락이면 넘기기를 끄고, 원래 크기면 켜고, 넘기면 배율 원래대로 (#12)', (t) async {
    await show(t, const PhotoViewer(ids: [101, 102, 103], start: 1));
    PageView view() => t.widget<PageView>(find.byType(PageView));
    TransformationController zoom(int i) => t.widget<InteractiveViewer>(find.byKey(ValueKey('zoom-$i'))).transformationController!;
    final center = t.getCenter(find.byType(PageView));
    Future<void> doubleTap() async {
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(center);
      await t.pump(const Duration(milliseconds: 400));
    }

    expect(view().physics, isNull);
    // 두 번 탭 → 확대, 넘기기 꺼짐, 옆으로 밀어도 같은 사진
    await doubleTap();
    expect(zoom(1).value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));
    expect(view().physics, isA<NeverScrollableScrollPhysics>());
    await t.drag(find.byType(PageView), const Offset(-300, 0));
    await anim(t);
    expect(find.textContaining('2 / 3'), findsOneWidget);
    // 다시 두 번 탭 → 원래 크기, 넘기기 켜짐
    await doubleTap();
    expect(zoom(1).value.getMaxScaleOnAxis(), closeTo(1, 0.001));
    expect(view().physics, isNull);
    // 손가락 두 개가 닿으면 꺼지고, 떼면 켜진다
    final a = await t.startGesture(center - const Offset(60, 0));
    final b = await t.startGesture(center + const Offset(60, 0));
    await t.pump();
    expect(view().physics, isA<NeverScrollableScrollPhysics>());
    // 벌렸다 오므리기: 확대했다가 원래 크기로
    for (var k = 0; k < 4; k++) {
      await a.moveBy(const Offset(-20, 0));
      await b.moveBy(const Offset(20, 0));
      await t.pump();
    }
    expect(zoom(1).value.getMaxScaleOnAxis(), greaterThan(1.5));
    for (var k = 0; k < 6; k++) {
      await a.moveBy(const Offset(20, 0));
      await b.moveBy(const Offset(-20, 0));
      await t.pump();
    }
    expect(zoom(1).value.getMaxScaleOnAxis(), closeTo(1, 0.001)); // minScale 1
    expect(view().physics, isA<NeverScrollableScrollPhysics>()); // 손가락이 아직 둘
    await a.up();
    await b.up();
    await t.pump();
    expect(view().physics, isNull);
    await t.pump(const Duration(milliseconds: 50));
    // 두 번째 손가락이 늦게 닿아 이미 넘기기가 시작됐으면 처음 페이지로 되돌린다
    final c = await t.startGesture(center);
    await c.moveBy(const Offset(-24, 0)); // 넘기기 문턱(18)은 넘고 확대 이동 문턱(36)은 안 넘게
    await t.pump();
    await c.moveBy(const Offset(-236, 0));
    await t.pump();
    expect(view().controller!.page, greaterThan(1.3));
    final d = await t.startGesture(center + const Offset(0, 80));
    await anim(t);
    expect(view().physics, isA<NeverScrollableScrollPhysics>());
    expect(view().controller!.page, closeTo(1, 0.001));
    await c.up();
    await d.up();
    await anim(t);
    expect(find.textContaining('2 / 3'), findsOneWidget);
    expect(view().physics, isNull);
    // 거의 원래 크기(넘기기 켜짐)로 남은 페이지는 다른 페이지로 넘어가면 원래대로
    zoom(1).value = Matrix4.diagonal3Values(1.005, 1.005, 1);
    await t.pump();
    expect(view().physics, isNull);
    await t.drag(find.byType(PageView), const Offset(-300, 0));
    await anim(t);
    expect(find.textContaining('3 / 3'), findsOneWidget);
    await t.drag(find.byType(PageView), const Offset(300, 0));
    await anim(t);
    expect(find.textContaining('2 / 3'), findsOneWidget);
    expect(zoom(1).value, Matrix4.identity());
    await cleanup(t);
  });

  testWidgets('크게 보기: 확대한 상태에서도 얼굴 상자를 누르면 그 얼굴이 잡힌다 (#12)', (t) async {
    scenario['photo'] = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXYxhwwMAAAACEAAHOfCFIAAAAAElFTkSuQmCC');
    await show(t, const PhotoViewer(ids: [7903]));
    await photoLoad(t);
    // 사진 가운데보다 왼쪽 위를 두 번 탭해 확대(얼굴 상자가 화면 안에 남게)
    final photo = find.byType(AspectRatio).last;
    Offset onPhoto(double x, double y) {
      final box = t.renderObject<RenderBox>(photo);
      return box.localToGlobal(Offset(box.size.width * x, box.size.height * y));
    }
    Offset faceCenter() => onPhoto(0.4, 0.325); // 상자 x .3~.5, y .2~.45
    final at = faceCenter();
    final zoomAt = onPhoto(0.25, 0.2); // 확대 중심(이 점만 제자리)
    await t.tapAt(zoomAt);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(zoomAt);
    await t.pump(const Duration(milliseconds: 400));
    final zoom = t.widget<InteractiveViewer>(find.byKey(const ValueKey('zoom-0'))).transformationController!;
    expect(zoom.value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));
    expect(faceCenter(), isNot(at)); // 확대로 화면 위 위치가 바뀌었다
    await t.tapAt(faceCenter());
    await t.pump(const Duration(milliseconds: 400)); // 두 번 탭 대기 시간이 지나야 한 번 탭으로 정해진다
    await anim(t);
    expect(find.text('이 얼굴은 누구인가요?'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('크게 보기: 확대해도 이름표 화면 크기가 같고 얼굴 상자 바로 아래 가운데를 따라간다', (t) async {
    scenario['photo'] = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXYxhwwMAAAACEAAHOfCFIAAAAAElFTkSuQmCC');
    await show(t, const PhotoViewer(ids: [7904]));
    await photoLoad(t);
    await t.pump();
    final label = find.byKey(const ValueKey('face-label-900'));
    expect(label, findsOneWidget);
    final photo = find.byType(AspectRatio).last;
    Offset onPhoto(double x, double y) {
      final box = t.renderObject<RenderBox>(photo);
      return box.localToGlobal(Offset(box.size.width * x, box.size.height * y));
    }
    final before = t.getRect(label); // getRect는 확대 변환까지 거친 화면 위 사각형
    // 얼굴(x .3~.5, 아래 끝 y .45)이 화면에 남게 왼쪽 위를 중심으로 2.5배
    final zoom = t.widget<InteractiveViewer>(find.byKey(const ValueKey('zoom-0'))).transformationController!;
    final c = t.renderObject<RenderBox>(find.byKey(const ValueKey('zoom-0'))).globalToLocal(onPhoto(0.3, 0.3));
    zoom.value = Matrix4.diagonal3Values(2.5, 2.5, 1)..setTranslationRaw(-c.dx * 1.5, -c.dy * 1.5, 0);
    await t.pump();
    final after = t.getRect(label);
    expect(after.width, closeTo(before.width, 0.5));
    expect(after.height, closeTo(before.height, 0.5));
    // 위치: 상자 아래 끝 바로 아래(화면 4px 틈), 상자 가운데에 맞춤
    final boxBottom = onPhoto(0.4, 0.45);
    expect(after.center.dx, closeTo(boxBottom.dx, 0.5));
    expect(after.top, closeTo(boxBottom.dy + 4, 0.5));
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
