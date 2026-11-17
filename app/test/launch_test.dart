// 시작 화면(#21): 아이콘·이름·문구, 홈으로 넘어가기, 진행 막대, 자리 고정, 큰 글씨·좁은 화면, 어두운 색, 최소 표시 시간.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

Map<String, Object?> prefs = {};
String? debugQuery; // MainActivity의 pt_query(_b64)로 받은 개발용 검색어 흉내: 한 번 가져가면 비운다

Future<Object?> fake(MethodCall call) async {
  switch (call.method) {
    case 'pref':
      return prefs[call.arguments['key']];
    case 'status':
      return {
        'photos_permission': true,
        'notifications': true,
        'battery_exempt': true,
        'manufacturer': 'Google',
        'running': false,
        'rest_why': null,
        'rest_left': 0,
        'night_on': true,
        'scan_phase': null,
        'scan_done': 0,
        'scan_total': 0,
        'photos': 10,
        'failed': 0,
        'faces_done': 10,
        'segments': 2,
        'vec_needed': 0,
        'vec_done': 0,
        'faces': 3,
        'reface_needed': 0,
        'reface_done': 0,
        'persons': 0,
      };
    case 'debugQuery':
      final q = debugQuery;
      debugQuery = null;
      return q;
    case 'runs':
    case 'people':
    case 'moments':
      return <Object?>[];
    default:
      return null;
  }
}

Future<void> open(
  WidgetTester t, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
  Future<bool> Function()? prepare,
  ValueListenable<bool>? ready,
  Widget Function(bool onboarded)? firstPage,
}) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  await t.pumpWidget(
    PhotoTracerApp(
      prepare: prepare ?? () async => true,
      ready: ready,
      firstPage: firstPage ?? (ob) => Scaffold(body: Center(child: Text(ob ? '홈 자리' : '처음 안내 자리'))),
    ),
  );
}

Rect rectOf(WidgetTester t, Key k) => t.getRect(find.byKey(k));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    prefs = {};
    debugQuery = null;
    SearchPage.debugQuery.value = null;
    Launch.homeReady.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, fake);
  });

  Future<void> cleanup(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    Status.i.stop();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    t.platformDispatcher.clearAllTestValues();
  }

  testWidgets('아이콘·이름·문구가 보이고 아이콘은 화면 정가운데 120dp', (t) async {
    await open(t, ready: ValueNotifier(false));
    await t.pump(const Duration(milliseconds: 250));
    expect(find.byKey(LaunchScreen.iconKey), findsOneWidget);
    expect(find.text(Launch.name), findsOneWidget);
    expect(find.text(Launch.tagline), findsOneWidget);
    final icon = rectOf(t, LaunchScreen.iconKey);
    expect(icon.size, const Size(120, 120));
    expect(icon.center, const Offset(195, 422));
    final name = rectOf(t, LaunchScreen.nameKey), line = rectOf(t, LaunchScreen.taglineKey);
    expect(name.top, closeTo(icon.bottom + 28, 0.01));
    expect(line.top, closeTo(name.bottom + 10, 0.01));
    expect(find.byKey(LaunchScreen.barKey), findsNothing); // 3초 전에는 막대 없음
    await cleanup(t);
  });

  testWidgets('준비가 끝나면 홈으로: 최소 0.6초는 보인다', (t) async {
    final ready = ValueNotifier(false);
    await open(t, ready: ready);
    await t.pump(const Duration(milliseconds: 50));
    ready.value = true; // 아주 빨리 끝남
    await t.pump(const Duration(milliseconds: 500)); // 0.55초
    expect(find.text(Launch.name), findsOneWidget);
    await t.pump(const Duration(milliseconds: 100)); // 0.65초: 사라지는 페이드 시작
    await t.pump(const Duration(milliseconds: 300)); // 페이드 끝
    await t.pump();
    expect(find.text(Launch.name), findsNothing);
    expect(find.text('홈 자리'), findsOneWidget);
    await cleanup(t);
  });

  for (final b in Brightness.values) {
    testWidgets('막대 색: 시작 화면 동안은 시작 화면 색(${b.name}), 걷히면 앱의 원래 색', (t) async {
      final ready = ValueNotifier(false);
      await open(t, brightness: b, ready: ready);
      await t.pump(const Duration(milliseconds: 250));
      final c = LaunchColors.of(b), icons = b == Brightness.dark ? Brightness.light : Brightness.dark;
      var s = SystemChrome.latestStyle!;
      expect(s.systemNavigationBarColor, c.bottom);
      expect(s.systemNavigationBarIconBrightness, icons);
      expect(s.systemNavigationBarContrastEnforced, isFalse);
      expect(s.statusBarColor, const Color(0x00000000));
      expect(s.statusBarIconBrightness, icons);
      // 걷힌 뒤 폰으로 보낸 막대 설정들. SystemChrome은 한 틈(microtask)에 마지막 것만 보낸다
      final sent = <Map<Object?, Object?>>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setSystemUIOverlayStyle') sent.add(call.arguments as Map<Object?, Object?>);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      ready.value = true;
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(find.text(Launch.name), findsNothing);
      // 앱의 원래 막대: 테마(밝게) 기준 MaterialApp 기본 — 탐색 막대 검정·흰 아이콘, 상태 막대 반투명 검정(FlutterActivity 기본)
      expect(sent.where((m) => m['statusBarColor'] == 0x40000000 && m['systemNavigationBarColor'] == 0xFF000000), isNotEmpty);
      s = SystemChrome.latestStyle!;
      expect(s.systemNavigationBarColor, const Color(0xFF000000));
      expect(s.systemNavigationBarIconBrightness, Brightness.light);
      expect(s.statusBarIconBrightness, icons, reason: '앱 테마(화면 모드 기본 = 시스템 따름)의 상태 막대 아이콘');
      await cleanup(t);
    });
  }

  testWidgets('준비가 0.6초보다 길면 그만큼만 보인다', (t) async {
    final ready = ValueNotifier(false);
    await open(t, ready: ready);
    await t.pump(const Duration(milliseconds: 1500));
    expect(find.text(Launch.name), findsOneWidget);
    ready.value = true;
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.text(Launch.name), findsNothing);
    expect(find.text('홈 자리'), findsOneWidget);
    await cleanup(t);
  });

  testWidgets('처음 실행이면 홈 목록을 기다리지 않고 처음 안내로', (t) async {
    await open(t, prepare: () async => false, ready: ValueNotifier(false));
    await t.pump(const Duration(milliseconds: 700));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.text(Launch.name), findsNothing);
    expect(find.text('처음 안내 자리'), findsOneWidget);
    await cleanup(t);
  });

  for (final q in [null, '바다']) {
    testWidgets('실제 홈: 첫 목록을 불러오면 시작 화면이 걷히고 아래 탭이 보인다${q == null ? '' : ' (개발용 검색어 주입 → 검색 탭)'}', (t) async {
      prefs['onboarded'] = '1';
      debugQuery = q;
      // 시작 화면과 상관없는 기존 경고는 건너뛴다: 앱 전체 스크롤 막대(_FastScroll)가 IndexedStack의 여러 탭 목록이 함께 쓰는
      // PrimaryScrollController에 붙어 디버그 검사("attached to more than one ScrollPosition")가 난다
      final original = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('more than one ScrollPosition')) original?.call(d);
      };
      addTearDown(() => FlutterError.onError = original);
      t.view.physicalSize = const Size(390, 844) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(const PhotoTracerApp());
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(Launch.homeReady.value, isTrue);
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(find.text(Launch.name), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      // pt_query_b64 통로: 시작 화면 밑에서 Shell이 검색어를 가져가 검색 탭으로 가 있다
      expect(t.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, q == null ? 0 : 1);
      if (q != null) expect(debugQuery, isNull, reason: '검색어를 가져갔다');
      await cleanup(t);
    });
  }

  testWidgets('탐색 막대가 있으면 그 위로 화면 높이 15% 넘게 띄운다', (t) async {
    t.view.padding = const FakeViewPadding(bottom: 48 * 3);
    t.view.viewPadding = const FakeViewPadding(bottom: 48 * 3);
    addTearDown(() {
      t.view.resetPadding();
      t.view.resetViewPadding();
    });
    await open(t, ready: ValueNotifier(false));
    await t.pump(const Duration(milliseconds: 3300));
    await t.pump(const Duration(milliseconds: 300));
    expect(rectOf(t, LaunchScreen.iconKey).center, const Offset(195, 422));
    final note = rectOf(t, LaunchScreen.noteKey);
    expect(note.isEmpty, isFalse);
    expect(844 - 48 - note.bottom, greaterThanOrEqualTo(844 * 0.15));
    await cleanup(t);
  });

  testWidgets('3초 넘으면 진행 막대, 나타나도 아이콘·이름·문구 자리는 그대로', (t) async {
    await open(t, ready: ValueNotifier(false));
    await t.pump(const Duration(milliseconds: 2900));
    expect(find.byKey(LaunchScreen.barKey), findsNothing);
    final before = [
      for (final k in [LaunchScreen.iconKey, LaunchScreen.nameKey, LaunchScreen.taglineKey]) rectOf(t, k),
    ];
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(LaunchScreen.barKey), findsOneWidget);
    expect(find.text(Launch.slowNote), findsOneWidget);
    final after = [
      for (final k in [LaunchScreen.iconKey, LaunchScreen.nameKey, LaunchScreen.taglineKey]) rectOf(t, k),
    ];
    expect(after, before);
    final bar = rectOf(t, LaunchScreen.barKey), note = rectOf(t, LaunchScreen.noteKey), line = before[2];
    expect(bar.size, const Size(160, 4));
    expect(bar.top, closeTo(line.bottom + 32, 0.01));
    expect(note.top, closeTo(bar.bottom + 10, 0.01));
    expect(note.bottom, lessThanOrEqualTo(844 * 0.85)); // 아래 여백 15% 이상
    await cleanup(t);
  });

  for (final (size, scale) in [(const Size(390, 844), 1.3), (const Size(320, 568), 1.0), (const Size(320, 568), 1.3)]) {
    testWidgets('겹침·화면 밖 없음: ${size.width.toInt()}×${size.height.toInt()} 글씨 $scale배', (t) async {
      await open(t, size: size, scale: scale, ready: ValueNotifier(false));
      await t.pump(const Duration(milliseconds: 250));
      final before = [
        for (final k in [LaunchScreen.iconKey, LaunchScreen.nameKey, LaunchScreen.taglineKey]) rectOf(t, k),
      ];
      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 300));
      final after = [
        for (final k in [LaunchScreen.iconKey, LaunchScreen.nameKey, LaunchScreen.taglineKey]) rectOf(t, k),
      ];
      expect(after, before, reason: '막대가 나타나도 위 묶음은 그대로');
      expect(before[0].center, Offset(size.width / 2, size.height / 2), reason: '글씨가 커져도 아이콘은 정가운데');
      final screen = Offset.zero & size;
      final parts = [...before, rectOf(t, LaunchScreen.barKey), rectOf(t, LaunchScreen.noteKey)].where((r) => !r.isEmpty).toList();
      expect(parts.length, 5, reason: '막대와 안내 글이 다 보여야 한다');
      for (final r in parts) {
        expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue, reason: '화면 밖: $r');
      }
      for (var i = 0; i < parts.length; i++) {
        for (var j = i + 1; j < parts.length; j++) {
          expect(parts[i].intersect(parts[j]).isEmpty || parts[i].intersect(parts[j]).height <= 0, isTrue, reason: '겹침: ${parts[i]} / ${parts[j]}');
        }
      }
      expect(t.takeException(), isNull); // 글자 넘침 없음
      await cleanup(t);
    });
  }

  testWidgets('어두운 테마 색과 밝은 테마 색', (t) async {
    Color bg() => t.widget<ColoredBox>(find.descendant(of: find.byType(LaunchScreen), matching: find.byType(ColoredBox)).first).color;
    Color? ink(Key k) => t.widget<Text>(find.byKey(k)).style?.color;

    await open(t, brightness: Brightness.dark, ready: ValueNotifier(false));
    await t.pump(const Duration(milliseconds: 250));
    expect(bg(), const Color(0xFF1B1916));
    expect(ink(LaunchScreen.nameKey), const Color(0xFFF3F4F6));
    expect(ink(LaunchScreen.taglineKey), const Color(0xFFD1D5DB));
    final g = t.widget<DecoratedBox>(find.descendant(of: find.byType(LaunchScreen), matching: find.byType(DecoratedBox)).first);
    expect(((g.decoration as BoxDecoration).gradient as LinearGradient).colors, const [Color(0xFF2A2119), Color(0xFF1C1916), Color(0xFF141518)]);
    await t.pump(const Duration(seconds: 3));
    expect(ink(LaunchScreen.noteKey), const Color(0xFFB4B9C4));
    await cleanup(t);

    await open(t, ready: ValueNotifier(false));
    await t.pump(const Duration(milliseconds: 250));
    expect(bg(), const Color(0xFFFFF1DE));
    expect(ink(LaunchScreen.nameKey), const Color(0xFF1B1C1F));
    expect(ink(LaunchScreen.taglineKey), const Color(0xFF3F4554));
    await cleanup(t);
  });

  testWidgets('TalkBack: "추억먹는하마, 불러오는 중" 한 번, 막대가 뜨면 안내 한 번', (t) async {
    final handle = t.ensureSemantics();
    await open(t, ready: ValueNotifier(false));
    await t.pump(const Duration(milliseconds: 250));
    expect(find.bySemanticsLabel(Launch.semanticsLabel), findsOneWidget);
    expect(t.getSemantics(find.bySemanticsLabel(Launch.semanticsLabel)), matchesSemantics(label: Launch.semanticsLabel, isLiveRegion: true));
    expect(find.bySemanticsLabel(Launch.name), findsNothing); // 이름·문구를 따로 또 읽지 않는다
    expect(find.bySemanticsLabel(Launch.tagline), findsNothing);
    expect(find.bySemanticsLabel(Launch.slowNote), findsNothing);
    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.bySemanticsLabel(Launch.slowNote), findsOneWidget);
    expect(t.getSemantics(find.bySemanticsLabel(Launch.slowNote)), matchesSemantics(label: Launch.slowNote, isLiveRegion: true));
    expect(find.bySemanticsLabel(Launch.semanticsLabel), findsOneWidget);
    expect(find.bySemanticsLabel('홈 자리'), findsNothing); // 시작 화면 밑의 홈은 아직 읽지 않는다
    await cleanup(t);
    handle.dispose();
  });
}
