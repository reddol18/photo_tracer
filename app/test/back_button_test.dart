// #30 뒤로가기: 다른 탭 → 홈 탭, 홈 → 앱을 끝내지 않고 뒤로 보내기(채널 'background'), 위에 push된 화면은 그것만 닫힘.
// 채널은 ui_smoke_test의 가짜(fake)에 'background'만 덧붙여 센다(폰 없이 PC에서).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

import 'ui_smoke_test.dart' show fake;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> backs; // 'background' 호출
  late List<String> systemPops; // SystemNavigator.pop(액티비티 끝내기) 호출

  setUp(() {
    backs = [];
    systemPops = [];
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'background') {
        backs.add(call.method);
        return true;
      }
      return fake(call);
    });
    m.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') systemPops.add(call.method);
      return null;
    });
  });

  tearDown(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(channel, null);
    m.setMockMethodCallHandler(SystemChannels.platform, null);
    Status.i.stop();
  });

  Future<void> show(WidgetTester t, Widget home) async {
    t.view.physicalSize = const Size(390, 844) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildTheme(const Color(0xFF2563EB), Brightness.light), home: home));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  int selectedTab(WidgetTester t) => t.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  Future<void> pressBack(WidgetTester t) async {
    await t.binding.handlePopRoute(); // 안드로이드 뒤로가기와 같은 길(엔진 → popRoute → Navigator.maybePop)
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> cleanup(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    Status.i.stop();
  }

  testWidgets('다른 탭에서 뒤로 → 홈 탭, 앱은 그대로', (t) async {
    await show(t, const Shell());
    for (final label in ['검색', '인물', '설정']) {
      await t.tap(find.text(label));
      await t.pump(const Duration(milliseconds: 100));
      expect(selectedTab(t), isNot(0));
      expect(HomePage.visible.value, isFalse);
      await pressBack(t);
      expect(selectedTab(t), 0, reason: '$label 탭에서 뒤로');
      expect(HomePage.visible.value, isTrue); // go()를 거쳐 홈이 보인다고 알렸다
    }
    expect(backs, isEmpty);
    expect(systemPops, isEmpty);
    await cleanup(t);
  });

  testWidgets('홈에서 뒤로 → 채널 background(끝내지 않음)', (t) async {
    await show(t, const Shell());
    expect(selectedTab(t), 0);
    await pressBack(t);
    expect(backs, ['background']);
    expect(systemPops, isEmpty);
    expect(find.byType(Shell), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('Shell 위에 push된 화면이 있으면 그 화면만 닫힌다', (t) async {
    await show(t, const Shell());
    await t.tap(find.text('인물'));
    await t.pump(const Duration(milliseconds: 100));
    final nav = t.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('위 화면'))));
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('위 화면'), findsOneWidget);

    await pressBack(t);
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('위 화면'), findsNothing);
    expect(selectedTab(t), 2); // 탭은 그대로(위 화면만 닫힘)
    expect(backs, isEmpty);
    expect(systemPops, isEmpty);
    await cleanup(t);
  });

  testWidgets('탭 안에서 연 바텀시트는 그것만 닫힌다', (t) async {
    await show(t, const Shell());
    await t.tap(find.text('설정'));
    await t.pump(const Duration(milliseconds: 100));
    final ctx = t.element(find.byType(NavigationBar));
    showModalBottomSheet<void>(context: ctx, builder: (_) => const SizedBox(height: 200, child: Text('시트')));
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('시트'), findsOneWidget);

    await pressBack(t);
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('시트'), findsNothing);
    expect(selectedTab(t), 3);
    expect(backs, isEmpty);
    await cleanup(t);
  });

  testWidgets('처음 안내: 뒤 단계에서 뒤로 → 앞 단계, 첫 단계에서 뒤로 → background', (t) async {
    await show(t, const OnboardingPage());
    await t.tap(find.text('계속하기'));
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('다음'), findsOneWidget);

    await pressBack(t);
    await t.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('계속하기'), findsOneWidget);
    expect(backs, isEmpty);

    await pressBack(t);
    expect(backs, ['background']);
    expect(systemPops, isEmpty);
    await cleanup(t);
  });
}
