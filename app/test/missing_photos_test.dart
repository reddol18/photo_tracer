// #37: 지운 사진·사라진 순간을 열어도 로딩이 끝없이 돌지 않는다.
// '읽는 중'과 '못 읽음'을 가르고(FacePhoto·Thumb·PhotosPage), 떠 있는 검색 결과·뷰어는 구간이 바뀌면(segmentsVersion) 사라진 것을 뺀다.
// 채널은 목으로 둔다(폰 없이 PC에서). 사진 id는 시험용 가짜 값이다.
import 'package:flutter/material.dart' hide Thumb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

final day = DateTime(2026, 10, 12, 15, 24).millisecondsSinceEpoch;

late Map<String, dynamic> st;
late Set<int> alive; // 목 DB에 남은 사진
late bool photoFails; // 'photo'·'thumb'이 오류(파일 없음이 아닌 다른 실패)
late List<Object?> checkReply; // checkMoments 답
late List<Map<String, dynamic>> checkArgs;

Future<Object?> fake(MethodCall call) async {
  final a = call.arguments is Map ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
  switch (call.method) {
    case 'people':
    case 'runs':
      return <Map<String, dynamic>>[];
    case 'status':
      return st;
    case 'photo':
    case 'thumb':
    case 'faceThumb':
      if (photoFails) throw PlatformException(code: call.method, message: '읽기 실패');
      return null; // Kotlin: 파일 없음(지운 사진)은 null
    case 'photoInfo':
      return null; // DB에도 없음
    case 'alivePhotos':
      return [for (final e in a['ids'] as List) if (alive.contains(e)) e];
    case 'checkMoments':
      checkArgs.add(a);
      return checkReply;
    case 'search':
      return {
        'items': [
          {'kind': 'segment', 'id': 5, 'cover': 100, 'n': 3, 'date': day, 'date_source': '카메라'},
          {'kind': 'segment', 'id': 6, 'cover': 200, 'n': 4, 'date': day - 86400000 * 3, 'date_source': '카메라'},
          {'kind': 'photo', 'id': 300, 'cover': 300, 'n': 1, 'date': day - 86400000 * 9, 'date_source': '카메라'},
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
    st = {'photos_permission': true, 'segments': 3, 'faces_done': 10, 'scan_phase': null, 'people_gen': 0, 'segments_gen': 0};
    alive = {};
    photoFails = false;
    checkReply = [];
    checkArgs = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, fake);
    await Status.i.refresh(); // 기준
  });

  tearDown(() {
    Status.i.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('사진을 못 읽으면 빈 상태', () {
    testWidgets('FacePhoto: 지운 사진(null)이면 스피너 대신 "지워졌어요", 얼굴 상자·이름표 없음', (t) async {
      await show(t, Scaffold(body: FacePhoto(9001, faces: const [{'id': 1, 'x': 0.1, 'y': 0.1, 'w': 0.2, 'h': 0.2, 'who': 1}], names: const {1: '딸'})));
      expect(find.text('이 사진은 지워졌어요'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('딸'), findsNothing);
      expect(find.byType(CustomPaint).evaluate().where((e) => (e.widget as CustomPaint).painter != null), isEmpty);
    });

    testWidgets('FacePhoto: 읽기 오류면 "읽을 수 없어요"(끝없는 로딩 아님)', (t) async {
      photoFails = true;
      await show(t, const Scaffold(body: FacePhoto(9002)));
      expect(find.text('이 사진을 읽을 수 없어요'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Thumb: 못 읽으면 회색 칸에 작은 아이콘', (t) async {
      await show(t, const Scaffold(body: SizedBox(width: 100, height: 100, child: Thumb(9003))));
      expect(find.byKey(const ValueKey('thumb-missing')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('PhotosPage', () {
    testWidgets('목록을 못 읽으면 오류 문구와 다시 시도', (t) async {
      var fail = true;
      await show(t, PhotosPage(title: '순간', load: () async => fail ? throw PlatformException(code: 'x') : [1, 2]));
      expect(find.text('사진 목록을 읽지 못했어요'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      fail = false;
      await t.tap(find.text('다시 시도'));
      await t.pump();
      await t.pump();
      expect(find.text('사진 목록을 읽지 못했어요'), findsNothing);
      expect(find.byType(Thumb), findsNWidgets(2));
    });

    testWidgets('순간의 사진이 0장이면 "모두 지워졌어요", 부제도 0장', (t) async {
      await show(t, PhotosPage(title: '순간', subtitleOf: (n) => '사진 ${n ?? 5}장', empty: PhotosPage.emptyMoment, load: () async => <int>[]));
      expect(find.text('이 순간의 사진이 모두 지워졌어요'), findsOneWidget);
      expect(find.text('사진 0장'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('순간이 아닌 목록의 0장은 일반 문구', (t) async {
      await show(t, PhotosPage(title: '화면 캡처', load: () async => <int>[]));
      expect(find.text(PhotosPage.emptyDefault), findsOneWidget);
    });
  });

  group('떠 있는 결과에서 사라진 것 빼기', () {
    testWidgets('segmentsVersion이 오르면 검색 결과의 사라진 칸을 빼고 장 수·안내 개수를 맞춘다(다시 검색 안 함)', (t) async {
      await show(t, const Scaffold(body: SearchPage()));
      await t.tap(find.text('캠핑'));
      await t.pump();
      await t.pump();
      expect(find.text('잘 맞는 순간 3개 · 사진 8장'), findsOneWidget);
      expect(find.text('사진 3장'), findsOneWidget);

      // 갤러리에서 첫 순간의 사진을 모두 지웠고, 둘째 순간은 표지를 포함해 두 장을 지웠다
      checkReply = [
        null,
        {'n': 2, 'cover': 201},
        {'n': 1, 'cover': 300},
      ];
      await bumpSegments(t);
      expect(checkArgs, hasLength(1));
      expect((checkArgs.single['items'] as List).map((e) => e['cover']), [100, 200, 300]);
      expect(find.text('사진 3장'), findsNothing); // 사라진 순간
      expect(find.text('사진 2장'), findsOneWidget); // 장 수 갱신
      expect(find.text('잘 맞는 순간 2개 · 사진 3장'), findsOneWidget);
      final covers = t.widgetList<Thumb>(find.byType(Thumb)).map((w) => w.id).toList();
      expect(covers, containsAll([201, 300]));
      expect(covers, isNot(contains(100)));
    });

    testWidgets('뷰어: 넘기는 목록의 지운 사진은 빈 상태로 보이고, 구간이 바뀌면 목록에서 빠진다', (t) async {
      alive = {1, 3};
      await show(t, const PhotoViewer(ids: [1, 2, 3], start: 0));
      expect(find.textContaining('1 / 3'), findsOneWidget);
      expect(find.text('이 사진은 지워졌어요'), findsOneWidget); // 목에서는 모든 사진이 null(빈 상태) — 멈추지 않는다
      await t.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await t.pumpAndSettle();
      expect(find.textContaining('2 / 3'), findsOneWidget); // 지운 사진 페이지에서도 넘겨진다
      expect(find.text('지워진 사진'), findsOneWidget);
      await t.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await t.pumpAndSettle();
      expect(find.textContaining('3 / 3'), findsOneWidget);

      await bumpSegments(t);
      expect(find.textContaining('2 / 2'), findsOneWidget); // 지운 2를 빼고 보던 3에 그대로
      await t.fling(find.byType(PageView), const Offset(300, 0), 1000);
      await t.pumpAndSettle();
      expect(find.textContaining('1 / 2'), findsOneWidget);
    });

    testWidgets('뷰어: 지금 보는 사진은 지웠어도 목록에 남긴다', (t) async {
      alive = {1, 3};
      await show(t, const PhotoViewer(ids: [1, 2, 3], start: 1));
      await bumpSegments(t);
      expect(find.textContaining('2 / 3'), findsOneWidget);
    });
  });
}
