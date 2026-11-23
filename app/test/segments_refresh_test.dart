// #31: 스캔이 구간을 바꾸면(status의 segments_gen) 구간 수가 같아도 홈 순간 카드(장 수·표지)를 제자리에서 다시 읽는다.
// #32: 검색 결과·홈 카드는 구간 번호만 들고 열지 않고 표지 사진·시작 시각을 함께 넘겨, 번호가 밀려도 맞는 순간이 열린다.
// 채널은 목으로 둔다(폰 없이 PC에서).
import 'package:flutter/material.dart' hide Thumb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

final day = DateTime(2026, 10, 12, 15, 24).millisecondsSinceEpoch;
const dayMs = 86400000;

// 목 DB
late int momentCount;
late int momentN; // 순간마다 장 수
late List<Map<String, dynamic>> momentArgs;
late List<Map<String, dynamic>> openArgs; // momentPhotos·segmentPhotos로 받은 인자
late Map<String, dynamic> st;

/// 목 Kotlin의 지금 구간: 표지 사진 → 구간 번호. 번호가 밀리면 이것만 바뀐다
late Map<int, int> segOfPhoto;
late Map<int, List<int>> photosOfSeg;

Future<Object?> fake(MethodCall call) async {
  final a = call.arguments is Map ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
  switch (call.method) {
    case 'people':
      return <Map<String, dynamic>>[];
    case 'status':
      return st;
    case 'runs':
      return <Map<String, dynamic>>[];
    case 'moments':
      momentArgs.add(a);
      final o = a['offset'] as int, l = a['limit'] as int;
      final all = [
        for (var i = 0; i < momentCount; i++)
          {'id': i, 'start': day - i * dayMs * 3, 'end': day - i * dayMs * 3 + 3600000, 'n': momentN, 'covers': [500 + i, 600 + i], 'people': <int>[]},
      ];
      return all.sublist(o.clamp(0, all.length), (o + l).clamp(0, all.length));
    case 'momentPhotos':
    case 'segmentPhotos':
      openArgs.add(a);
      // Kotlin Moments.resolve처럼: 표지 사진이 든 구간이 먼저, 없으면 번호
      final seg = segOfPhoto[a['photo']] ?? a['id'] as int;
      return photosOfSeg[seg] ?? <int>[];
    case 'search':
      return {
        'items': [
          {'kind': 'segment', 'id': 5, 'cover': 100, 'n': 3, 'date': day, 'date_source': '카메라'},
        ],
        'words': <Map<String, dynamic>>[],
        'rest': a['q'],
      };
  }
  return null;
}

Future<void> show(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(390, 844) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: w));
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> anim(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// 열린 순간 사진 목록(PhotosPage)에 보이는 사진 id
List<int> shown(WidgetTester t) =>
    t.widgetList<Thumb>(find.descendant(of: find.byType(PhotosPage), matching: find.byType(Thumb))).map((w) => w.id).toList();

/// status의 segments_gen을 올리고 Status가 읽게 한다(runAsync 밖: 듣는 쪽 타이머가 시험 시계를 따르게)
Future<void> bumpSegments(WidgetTester t) async {
  st = {...st, 'segments_gen': (st['segments_gen'] as int) + 1};
  await Status.i.refresh();
  await t.pump(peopleSettle);
  await t.pump();
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    momentCount = 3;
    momentN = 5;
    momentArgs = [];
    openArgs = [];
    segOfPhoto = {100: 5, 500: 0};
    photosOfSeg = {5: [101, 102, 103], 0: [501, 502]};
    st = {'photos_permission': true, 'segments': 3, 'faces_done': 10, 'scan_phase': null, 'people_gen': 0, 'segments_gen': 0};
    HomePage.visible.value = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, fake);
    await Status.i.refresh(); // 기준
  });

  tearDown(() {
    Status.i.stop();
    HomePage.visible.value = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('#31 segments_gen', () {
    testWidgets('status의 segments_gen이 바뀌면 segmentsVersion을 한 번 올린다', (t) async {
      final v0 = segmentsVersion.value;
      await t.runAsync(() => Status.i.refresh());
      expect(segmentsVersion.value, v0); // 그대로면 그대로
      st = {...st, 'segments_gen': 1};
      await t.runAsync(() => Status.i.refresh());
      expect(segmentsVersion.value, v0 + 1);
      await t.runAsync(() => Status.i.refresh());
      expect(segmentsVersion.value, v0 + 1);
    });

    testWidgets('구간 수가 같아도 segments_gen이 바뀌면 홈 순간을 제자리에서 다시 읽는다', (t) async {
      momentCount = 30;
      await show(t, const Scaffold(body: HomePage()));
      expect(find.text('사진 5장'), findsWidgets);
      ScrollPosition pos() => t.state<ScrollableState>(find.byType(Scrollable).first).position;
      await t.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await anim(t);
      final at = pos().pixels;
      expect(at, greaterThan(300));
      final before = momentArgs.length;

      momentN = 6; // 새 사진이 기존 순간에 붙었다 — 구간 수(status의 segments)는 그대로
      await bumpSegments(t);
      expect(momentArgs.length, before + 1);
      expect(momentArgs.last['offset'], 0); // 불러온 범위 그대로
      expect(find.text('사진 6장'), findsWidgets);
      expect(pos().pixels, at); // 맨 위로 튀지 않는다
    });

    testWidgets('구간이 그대로면(segments_gen 같음) 다시 읽지 않는다', (t) async {
      await show(t, const Scaffold(body: HomePage()));
      final before = momentArgs.length;
      st = {...st, 'segments': 4}; // 수만 바뀌고 번호가 그대로인 일은 없지만, 이제 수로는 다시 읽지 않는다(중복 없음)
      await Status.i.refresh();
      await t.pump(peopleSettle);
      await t.pump();
      expect(momentArgs.length, before);
    });

    testWidgets('홈이 안 보일 때는 표시만 하고, 보일 때 읽는다', (t) async {
      await show(t, const Scaffold(body: HomePage()));
      final before = momentArgs.length;
      HomePage.visible.value = false;
      momentN = 4; // 갤러리에서 사진을 지웠다
      await bumpSegments(t);
      expect(momentArgs.length, before);

      HomePage.visible.value = true;
      await t.pump();
      await t.pump();
      expect(momentArgs.length, before + 1);
      expect(find.text('사진 4장'), findsWidgets);
    });
  });

  group('#32 순간을 번호 말고 표지 사진으로 연다', () {
    testWidgets('검색 결과를 띄운 사이 번호가 밀려도 맞는 순간이 열린다', (t) async {
      await show(t, const Scaffold(body: SearchPage()));
      await t.tap(find.text('캠핑'));
      await t.pump();
      await t.pump();
      expect(find.text('사진 3장'), findsOneWidget);

      // 결과를 띄운 사이 옛 날짜 사진이 들어와 구간 번호가 하나씩 밀렸다: 표지 100은 이제 6번, 5번은 다른 날
      segOfPhoto = {100: 6};
      photosOfSeg = {5: [901, 902], 6: [101, 102, 103]};
      await t.tap(find.text('사진 3장'));
      await anim(t);
      expect(openArgs.last['photo'], 100);
      expect(openArgs.last['start'], day);
      expect(shown(t), [101, 102, 103]); // 5번(다른 날)의 사진이 아님
    });

    testWidgets('홈 카드도 표지 사진·시작·끝을 넘기고, 열어 둔 사이 구간이 바뀌면 같은 순간을 다시 읽는다', (t) async {
      await show(t, const Scaffold(body: HomePage()));
      await t.tap(find.text('사진 5장').first);
      await anim(t);
      expect(openArgs.last['photo'], 500);
      expect(openArgs.last['start'], day);
      expect(openArgs.last['end'], day + 3600000);
      expect(shown(t), [501, 502]);

      // 보는 사이 번호가 밀리고(표지 500은 이제 1번) 사진이 붙었다
      segOfPhoto = {500: 1};
      photosOfSeg = {0: [801], 1: [501, 502, 503]};
      final n0 = openArgs.length;
      await bumpSegments(t);
      expect(openArgs.length, n0 + 1);
      expect(openArgs.last['photo'], 500);
      expect(shown(t), [501, 502, 503]); // 같은 순간(0번의 801이 아님)
    });
  });
}
