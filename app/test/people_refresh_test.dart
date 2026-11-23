// #27: 인물 탭은 IndexedStack에 남아 있어서, 다른 곳에서 인물을 바꾸면 알림(peopleVersion·PeoplePage.shown)으로 다시 읽어야 한다.
// 채널은 목으로 둔다(폰 없이 PC에서).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

Map<String, dynamic> person(int id, String name) =>
    {'id': id, 'name': name, 'relation': null, 'birth_year': null, 'n': 10 * id, 'refs': 1, 'face': null};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> stored; // 목 DB의 등록 인물
  late List<String> calls;

  setUp(() {
    stored = [person(1, '엄마')];
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'people':
          return [for (final p in stored) Map<String, dynamic>.from(p)];
        case 'persons':
          return <Map<String, dynamic>>[];
        case 'reviewQueue':
          return {'total': 0, 'items': <Map<String, dynamic>>[]};
        case 'whoCreate':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          stored.add(person(stored.length + 1, args['name'] as String));
          return stored.length;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('다른 화면에서 인물을 등록하면(changePeople) 인물 탭이 다시 읽는다', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: PeoplePage())));
    await t.pumpAndSettle();
    expect(find.text('등록한 인물 1명'), findsOneWidget);

    // 홈·검색의 크게 보기에서 등록한 것처럼: 인물 탭 밖에서 채널을 부른다
    await changePeople('whoCreate', {'name': '아빠', 'faces': [7]});
    await changePeople('whoCreate', {'name': '딸', 'faces': [8]});
    await t.pump(peopleSettle); // 듣는 쪽이 잠깐 모았다가 한 번 읽는다(#29)
    await t.pumpAndSettle();
    expect(find.text('등록한 인물 3명'), findsOneWidget);
    expect(find.text('딸'), findsWidgets); // 이름 + 얼굴 없는 아바타의 첫 글자
  });

  testWidgets('인물 탭으로 들어오면(PeoplePage.shown) 다시 읽는다', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: PeoplePage())));
    await t.pumpAndSettle();
    expect(find.text('등록한 인물 1명'), findsOneWidget);

    stored.add(person(2, '아빠')); // 알림 없이 바뀐 것(예: 밤 정리) — 탭에 들어오면 보여야 한다
    PeoplePage.shown.value++;
    await t.pumpAndSettle();
    expect(find.text('등록한 인물 2명'), findsOneWidget);
  });

  testWidgets('인물 정보 창: 작은 화면에서 키보드가 올라와도 넘치지 않는다', (t) async {
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1;
    t.view.viewInsets = const FakeViewPadding(bottom: 300); // 키보드
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => askPerson(context, '새 인물'), child: const Text('열기')))),
    ));
    await t.tap(find.text('열기'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('태어난 해 (선택)'), findsOneWidget);
  });

  testWidgets('늦게 온 옛 결과는 새 결과를 덮지 않는다', (t) async {
    // 첫 'people' 답만 늦게 온다
    var first = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'people':
          final snapshot = [for (final p in stored) Map<String, dynamic>.from(p)];
          if (first) {
            first = false;
            await Future<void>.delayed(const Duration(seconds: 1));
          }
          return snapshot;
        case 'persons':
          return <Map<String, dynamic>>[];
        case 'reviewQueue':
          return {'total': 0, 'items': <Map<String, dynamic>>[]};
      }
      return null;
    });
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: PeoplePage())));
    await t.pump();
    stored.add(person(2, '아빠'));
    peopleVersion.value++; // 두 번째 load: 바로 답한다(2명)
    await t.pump();
    await t.pump();
    await t.pump(const Duration(seconds: 2)); // 첫 load의 옛 답(1명)이 이제 온다
    await t.pumpAndSettle();
    expect(find.text('등록한 인물 2명'), findsOneWidget);
  });
}
