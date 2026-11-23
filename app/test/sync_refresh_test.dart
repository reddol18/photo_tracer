// #29: 인물을 바꾼 것이 다른 화면(홈 순간·순간 사진 목록·뷰어의 다른 사진)에 반영되는지,
// 다시 묶기·밤 정리 끝(status의 people_gen)이 화면에 알려지는지, 다시 읽기가 몰리지 않는지(디바운스).
// 채널은 목으로 둔다(폰 없이 PC에서). 이름은 일반 호칭만 쓴다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

final day = DateTime(2026, 10, 12, 15, 24).millisecondsSinceEpoch;

Map<String, dynamic> person(int id, String name) =>
    {'id': id, 'name': name, 'relation': null, 'birth_year': null, 'n': 10, 'refs': 1, 'face': null};

// 8x4 PNG (뷰어 사진)
final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXYxhwwMAAAACEAAHOfCFIAAAAAElFTkSuQmCC');

// 목 DB
late List<Map<String, dynamic>> stored; // 등록 인물
late List<int> momentPeople; // 순간 카드의 인물
late int momentCount; // 순간 수
late Map<int, int?> faceWho; // 뷰어 사진 → 그 사진 얼굴의 who
late Map<String, int> calls; // 채널 이름 → 부른 횟수
late List<Map<String, dynamic>> momentArgs;
late Map<String, dynamic> st; // status

Future<Object?> fake(MethodCall call) async {
  calls.update(call.method, (n) => n + 1, ifAbsent: () => 1);
  final a = call.arguments is Map ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
  switch (call.method) {
    case 'people':
      return [for (final p in stored) Map<String, dynamic>.from(p)];
    case 'status':
      return st;
    case 'runs':
      return <Map<String, dynamic>>[];
    case 'moments':
      momentArgs.add(a);
      final o = a['offset'] as int, l = a['limit'] as int;
      final all = [
        for (var i = 0; i < momentCount; i++)
          {'id': i, 'start': day - i * 86400000 * 3, 'end': day - i * 86400000 * 3 + 3600000, 'n': 5, 'covers': <int>[], 'people': momentPeople},
      ];
      return all.sublist(o.clamp(0, all.length), (o + l).clamp(0, all.length));
    case 'photo':
      return png;
    case 'photoInfo':
      final id = (a['id'] as num).toInt();
      return {'taken': day, 'date_source': 'exif', 'received': null, 'faces': [
        {'id': id + 1000, 'x': 0.3, 'y': 0.2, 'w': 0.2, 'h': 0.25, 'person': 7, 'who': faceWho[id], 'maybe': null, 'sim': 0.6},
      ]};
    case 'whoCreate':
      // 새 인물 등록: Kotlin은 assignAll로 닮은 다른 사진의 얼굴에도 이름을 붙인다
      stored.add(person(2, a['name'] as String));
      faceWho.updateAll((k, v) => 2);
      return 2;
    case 'persons':
      return <Map<String, dynamic>>[];
    case 'reviewQueue':
      return {'total': 0, 'items': <Map<String, dynamic>>[]};
    case 'clusterInfo':
      return {'running': st['clustering'] ?? 0, 'full_ms': 1000, 'full_faces': 10, 'faces': 10, 'full_at': day, 'added': 0, 'added_at': 0};
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

/// 화면 넘김 애니메이션이 끝날 만큼(도는 표시가 있어 pumpAndSettle은 쓰지 않는다)
Future<void> anim(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// 뷰어의 그 사진(얼굴 좌표 기준 상자)
Finder photoOf(int id) =>
    find.descendant(of: find.byWidgetPredicate((w) => w is FacePhoto && w.id == id), matching: find.byType(AspectRatio));

/// 사진 풀기(진짜 비동기)
Future<void> photoLoad(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await t.pump();
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    stored = [person(1, '엄마')];
    momentPeople = [1];
    momentCount = 3;
    faceWho = {};
    calls = {};
    momentArgs = [];
    st = {'photos_permission': true, 'segments': 3, 'faces_done': 10, 'scan_phase': null, 'people_gen': 0};
    HomePage.visible.value = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, fake);
  });

  tearDown(() {
    Status.i.stop();
    HomePage.visible.value = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('A 홈 순간', () {
    testWidgets('인물이 바뀌면 순간 카드의 이름도 다시 읽는다', (t) async {
      await show(t, const Scaffold(body: HomePage()));
      expect(find.text('사진 5장 · 엄마'), findsWidgets);
      final before = momentArgs.length;

      stored.add(person(2, '아빠'));
      momentPeople = [1, 2];
      await changePeople('whoMark', {'id': 2, 'faces': [1], 'ok': true});
      await t.pump(peopleSettle);
      await t.pump();
      await t.pump();
      expect(momentArgs.length, before + 1);
      expect(momentArgs.last['offset'], 0);
      expect(find.text('사진 5장 · 엄마, 아빠'), findsWidgets);
    });

    testWidgets('다시 읽어도 보던 자리를 지킨다', (t) async {
      momentCount = 30;
      await show(t, const Scaffold(body: HomePage()));
      ScrollPosition pos() => t.state<ScrollableState>(find.byType(Scrollable).first).position;
      await t.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await anim(t);
      final at = pos().pixels;
      expect(at, greaterThan(300));

      momentPeople = [1, 2];
      stored.add(person(2, '아빠'));
      peopleVersion.value++;
      await t.pump(peopleSettle);
      await t.pump();
      await t.pump();
      expect(find.text('사진 5장 · 엄마, 아빠'), findsWidgets);
      expect(pos().pixels, at);
    });

    testWidgets('홈이 안 보일 때는 표시만 하고, 보일 때 읽는다', (t) async {
      await show(t, const Scaffold(body: HomePage()));
      final before = momentArgs.length;
      HomePage.visible.value = false;

      momentPeople = [1, 2];
      stored.add(person(2, '아빠'));
      peopleVersion.value++;
      await t.pump(peopleSettle);
      await t.pump();
      expect(momentArgs.length, before); // 숨어 있으면 순간은 읽지 않는다

      HomePage.visible.value = true;
      await t.pump();
      await t.pump();
      expect(momentArgs.length, before + 1);
      expect(find.text('사진 5장 · 엄마, 아빠'), findsWidgets);

      HomePage.visible.value = false; // 더 바뀐 것이 없으면 다시 보여도 읽지 않는다
      HomePage.visible.value = true;
      await t.pump();
      expect(momentArgs.length, before + 1);
    });

    testWidgets('판 번호가 줄줄이 올라도 한 번만 읽는다(디바운스)', (t) async {
      await show(t, const Scaffold(body: HomePage()));
      final people0 = calls['people'] ?? 0, moments0 = momentArgs.length;
      for (var i = 0; i < 5; i++) {
        peopleVersion.value++;
        await t.pump(const Duration(milliseconds: 100)); // 빠르게 답하기
      }
      await t.pump(peopleSettle);
      await t.pump();
      await t.pump();
      expect(calls['people']! - people0, 1);
      expect(momentArgs.length - moments0, 1);
    });
  });

  group('B 순간 사진 목록', () {
    testWidgets('인물이 바뀌면 다시 읽는다', (t) async {
      var photos = [11, 12, 13];
      var loads = 0;
      await show(t, PhotosPage(title: '순간', load: () async {
        loads++;
        return photos;
      }));
      expect(find.text('사진 3장'), findsOneWidget);

      photos = [11, 13]; // 뷰어에서 '아니에요' → 이 인물로 거른 목록에서 빠진다
      for (var i = 0; i < 3; i++) {
        peopleVersion.value++;
      }
      await t.pump(peopleSettle);
      await t.pump();
      expect(loads, 2);
      expect(find.text('사진 2장'), findsOneWidget);
    });

    testWidgets('뷰어에서 돌아오면 바로 다시 읽는다', (t) async {
      var photos = [21, 22, 23];
      var loads = 0;
      await show(t, PhotosPage(title: '순간', load: () async {
        loads++;
        return photos;
      }));
      await t.tap(find.byType(GestureDetector).first);
      await anim(t);
      expect(find.byType(PhotoViewer), findsOneWidget);

      photos = [21];
      peopleVersion.value++; // 뷰어에서 바꾸고
      t.state<NavigatorState>(find.byType(Navigator)).pop(); // 곧바로 돌아온다
      await t.pump();
      await t.pump();
      expect(loads, 2); // 기다리지 않고 바로
      await anim(t);
      await t.pump(peopleSettle);
      expect(loads, 2); // 모아 둔 다시 읽기는 지웠다
      expect(find.text('사진 1장'), findsOneWidget);
    });
  });

  group('C 뷰어', () {
    testWidgets('새 인물을 등록하면 이미 넘겨 본 다른 사진의 이름표도 새로', (t) async {
      faceWho = {8801: null, 8802: null};
      await show(t, const PhotoViewer(ids: [8801, 8802]));
      await photoLoad(t);
      // 옆 사진을 한 번 보고(얼굴 정보가 캐시에 들어간다) 돌아온다
      await t.drag(find.byType(PageView), const Offset(-300, 0));
      await anim(t);
      await photoLoad(t);
      expect(find.textContaining('2 / 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('face-label-9802')), findsNothing);
      await t.drag(find.byType(PageView), const Offset(300, 0));
      await anim(t);
      await photoLoad(t);
      expect(find.textContaining('1 / 2'), findsOneWidget);

      // 얼굴을 눌러 새 인물 '아빠' 등록
      await t.pump(const Duration(seconds: 1)); // 넘김이 완전히 멈추게(움직이는 중의 탭은 멈추기로 먹힌다)
      final box = t.renderObject<RenderBox>(photoOf(8801));
      await t.tapAt(box.localToGlobal(Offset(box.size.width * 0.4, box.size.height * 0.325)));
      await t.pump(const Duration(milliseconds: 400));
      await anim(t);
      expect(find.text('이 얼굴은 누구인가요?'), findsOneWidget);
      await t.tap(find.text('새 인물'));
      await anim(t);
      await t.enterText(find.byType(TextField).first, '아빠');
      await t.tap(find.text('확인'));
      await anim(t);
      await photoLoad(t);
      expect(find.byKey(const ValueKey('face-label-9801')), findsOneWidget);

      // 옆 사진으로 넘기면 다시 읽어 Kotlin이 붙인 이름이 보인다
      await t.drag(find.byType(PageView), const Offset(-300, 0));
      await anim(t);
      await photoLoad(t);
      expect(find.byKey(const ValueKey('face-label-9802')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('face-label-9802')), matching: find.text('아빠')), findsOneWidget);
      await t.pump(peopleSettle);
    });

    testWidgets('밖에서 인물이 바뀌면(peopleVersion) "누구인가요?" 시트의 인물도 새로', (t) async {
      faceWho = {8803: 1};
      await show(t, const PhotoViewer(ids: [8803]));
      await photoLoad(t);
      stored.add(person(2, '아빠'));
      peopleVersion.value++;
      await t.pump(peopleSettle);
      await t.pump();
      await photoLoad(t);
      final box = t.renderObject<RenderBox>(photoOf(8803));
      await t.tapAt(box.localToGlobal(Offset(box.size.width * 0.4, box.size.height * 0.325)));
      await t.pump(const Duration(milliseconds: 400));
      await anim(t);
      expect(find.text('이 얼굴은 누구인가요?'), findsOneWidget);
      expect(find.text('아빠'), findsOneWidget);
    });
  });

  group('D·E 화면 밖에서 끝난 다시 묶기·밤 정리', () {
    testWidgets('status의 people_gen이 바뀌면 peopleVersion을 한 번 올린다', (t) async {
      final v0 = peopleVersion.value;
      st = {...st, 'people_gen': 5};
      await t.runAsync(() => Status.i.refresh());
      expect(peopleVersion.value, v0); // 처음 읽은 값은 기준
      await t.runAsync(() => Status.i.refresh());
      expect(peopleVersion.value, v0); // 그대로면 그대로
      st = {...st, 'people_gen': 6};
      await t.runAsync(() => Status.i.refresh());
      expect(peopleVersion.value, v0 + 1);
      await t.runAsync(() => Status.i.refresh());
      expect(peopleVersion.value, v0 + 1);
    });

    testWidgets('인물 탭은 다시 묶기 끝(status)을 받아 다시 읽는다', (t) async {
      // runAsync 밖에서 불러야 peopleVersion을 듣는 쪽의 타이머가 시험 시계(pump)를 따른다
      await Status.i.refresh(); // 기준
      await show(t, const Scaffold(body: PeoplePage()));
      final n0 = calls['persons'] ?? 0;
      st = {...st, 'people_gen': (st['people_gen'] as int) + 1};
      await Status.i.refresh();
      await t.pump(peopleSettle);
      await t.pump();
      expect(calls['persons']! - n0, 1);
    });

    testWidgets('자주 보이는 얼굴 화면의 진행 확인은 peopleVersion을 따로 올리지 않는다(중복 알림 없음)', (t) async {
      st = {...st, 'clustering': day};
      await show(t, const ClustersPage());
      final v0 = peopleVersion.value;
      st = {...st, 'clustering': 0};
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      await t.pump();
      expect(find.textContaining('다시 묶는 중'), findsNothing);
      expect(peopleVersion.value, v0);
    });
  });
}
