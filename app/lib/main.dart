import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'vendors.dart';

part 'ui/common.dart';
part 'ui/launch.dart';
part 'ui/onboarding.dart';
part 'ui/home.dart';
part 'ui/period_sheet.dart';
part 'ui/night.dart';
part 'ui/search.dart';
part 'ui/people.dart';
part 'ui/review.dart';
part 'ui/settings.dart';
part 'ui/viewer.dart';

/// Photo Tracer: 설치 → 충전 중인 밤에 사진 정리 → 홈(순간)·검색·인물.
/// 화면은 lib/ui/ 아래 파일들(이 파일의 part), 분석은 모두 Kotlin(android/app/src/main/kotlin)에서 한다.
const channel = MethodChannel('app');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 시스템 시작 화면이 보이는 동안 아이콘만 풀어 둔다(첫 프레임부터 같은 아이콘). 나머지 준비는 Flutter 시작 화면이 보이는 동안 한다
  await Launch.prepare();
  // 첫 프레임 전에 막대를 시작 화면 색으로(그러지 않으면 시스템 시작 화면 → Flutter 사이 한 프레임 탐색 막대가 검게 보인다)
  SystemChrome.setSystemUIOverlayStyle(Launch.barsFor(ui.PlatformDispatcher.instance.platformBrightness));
  runApp(const PhotoTracerApp());
}

/// 앱 뿌리. 첫 프레임부터 시작 화면(lib/ui/launch.dart)을 덮어 두고, 화면 설정을 읽은 뒤 원래 첫 화면(홈 또는 처음 안내)을
/// 그 밑에 띄운다. 홈이면 첫 목록까지 기다렸다가(최소 0.6초) 시작 화면을 걷는다
class PhotoTracerApp extends StatefulWidget {
  const PhotoTracerApp({super.key, this.prepare = Launch.loadPrefs, this.firstPage, this.ready});

  /// 시작 화면 동안 할 준비. 돌려주는 값: 처음 안내를 봤는지
  final Future<bool> Function() prepare;

  /// 테스트용: 첫 화면과 그 화면의 준비 신호를 바꿔 끼운다(기본은 홈·처음 안내와 Launch.homeReady)
  final Widget Function(bool onboarded)? firstPage;
  final ValueListenable<bool>? ready;

  @override
  State<PhotoTracerApp> createState() => _PhotoTracerAppState();
}

class _PhotoTracerAppState extends State<PhotoTracerApp> {
  final onboarded = ValueNotifier<bool?>(null); // null: 아직 화면 설정을 읽는 중
  bool slow = false, leaving = false, gone = false, finishing = false, minPassed = false;
  Timer? slowTimer, giveUpTimer, minTimer;

  ValueListenable<bool> get ready => widget.ready ?? Launch.homeReady;

  @override
  void initState() {
    super.initState();
    slowTimer = Timer(Launch.slowAfter, () {
      if (mounted && !leaving) setState(() => slow = true);
    });
    giveUpTimer = Timer(Launch.giveUp, finish);
    // 최소 표시 시간: 준비가 그 전에 끝나면 이때 걷는다
    minTimer = Timer(Launch.minShow, () {
      minPassed = true;
      if (finishing) leave();
    });
    start();
  }

  Future<void> start() async {
    var ob = false;
    try {
      ob = await widget.prepare();
    } catch (_) {}
    if (!mounted) return;
    onboarded.value = ob;
    // 처음 안내는 따로 불러올 목록이 없다. 홈은 첫 목록이 올 때까지
    if (!ob || ready.value) {
      finish();
    } else {
      ready.addListener(onReady);
    }
  }

  void onReady() {
    if (ready.value) finish();
  }

  void finish() {
    if (finishing || !mounted) return;
    finishing = true;
    ready.removeListener(onReady);
    giveUpTimer?.cancel();
    if (minPassed) leave();
  }

  void leave() {
    if (!mounted) return;
    slowTimer?.cancel();
    setState(() => leaving = true);
  }

  @override
  void dispose() {
    slowTimer?.cancel();
    giveUpTimer?.cancel();
    minTimer?.cancel();
    ready.removeListener(onReady);
    onboarded.dispose();
    super.dispose();
  }

  static Widget _first(bool ob) => ob ? const Shell() : const OnboardingPage();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: Look.current,
        builder: (context, look, _) => MaterialApp(
          title: '추억먹는하마',
          theme: buildTheme(look.accent, Brightness.light),
          darkTheme: buildTheme(look.accent, Brightness.dark),
          themeMode: look.mode,
          scrollBehavior: const _FastScroll(),
          home: ValueListenableBuilder<bool?>(
            valueListenable: onboarded,
            builder: (context, ob, _) => ob == null ? const SizedBox.shrink() : (widget.firstPage ?? _first)(ob),
          ),
          // 첫 화면은 늘 Stack의 0번 자리에 둔다: 시작 화면(1번)을 빼도 첫 화면 상태(목록·탭)가 그대로 이어진다
          builder: (context, child) => Stack(fit: StackFit.expand, children: [
            ExcludeSemantics(excluding: !leaving && !gone, child: child ?? const SizedBox.shrink()),
            if (!gone)
              IgnorePointer(
                ignoring: leaving,
                child: LaunchScreen(leaving: leaving, slow: slow, onGone: () {
                  setState(() => gone = true);
                  // 홈으로 넘어간 뒤 막대는 앱의 원래 색으로(앱 테마 밝기 기준)
                  SystemChrome.setSystemUIOverlayStyle(Launch.appBars(Theme.of(context).brightness));
                }),
              ),
          ]),
        ),
      );
}

/// 스크롤되는 곳마다 전체 중 어디쯤인지 보여 주는 반투명 막대. 막대를 끌면 사진 그리드처럼 긴 목록도 빨리 넘긴다.
/// 안드로이드 기본은 막대가 없어서(데스크톱만 그린다) 모든 스크롤에 직접 단다. 한 줄 입력칸은 Flutter가 알아서 뺀다
class _FastScroll extends MaterialScrollBehavior {
  const _FastScroll();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    final vertical = axisDirectionToAxis(details.direction) == Axis.vertical;
    return RawScrollbar(
      controller: details.controller,
      thumbVisibility: vertical,
      interactive: true, // 손가락으로 막대를 끌어 스크롤 (터치는 막대 둘레 48px까지 잡힌다)
      thickness: vertical ? 6 : 4,
      radius: const Radius.circular(3),
      minThumbLength: 48, // 사진이 수천 장이어도 잡을 수 있게
      thumbColor: Theme.of(context).colorScheme.onSurface.withAlpha(60),
      child: child,
    );
  }
}

/// 아래 탭 4개: 홈 · 검색 · 인물 · 설정. 정리 상태는 탭과 상관없이 Status가 읽어 둔다
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Status.i.start();
    if (kDebugMode) {
      // 개발용 확인 통로 — 출시 전 정리 대상: 앱이 떠 있을 때 adb 검색어가 오면 Kotlin이 알린다
      channel.setMethodCallHandler((call) async {
        if (call.method == 'debugQueryReady') takeDebugQuery();
      });
      takeDebugQuery();
    }
  }

  /// 개발용 확인 통로 — 출시 전 정리 대상: adb로 넣은 검색어(MainActivity의 pt_query)가 있으면 검색 탭으로 가서 검색한다
  Future<void> takeDebugQuery() async {
    if (!kDebugMode) return;
    try {
      final q = await channel.invokeMethod<String>('debugQuery');
      if (q == null || q.trim().isEmpty || !mounted) return;
      setState(() => tab = 1);
      SearchPage.debugQuery.value = q;
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 설정 화면에서 돌아오면 권한 상태를 다시 읽고, 새 사진이 있나 갤러리를 다시 본다
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Status.i.refresh(scan: true);
      if (kDebugMode) takeDebugQuery(); // 개발용 확인 통로 — 출시 전 정리 대상
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: IndexedStack(index: tab, children: [
            HomePage(onSearch: () => setState(() => tab = 1)),
            const SearchPage(),
            const PeoplePage(),
            const SettingsPage(),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) {
            // 인물 탭에 들어올 때마다 다시 읽게 알린다(#27). 같은 탭을 또 눌러도 새로 읽는다
            if (i == 2) PeoplePage.shown.value++;
            setState(() => tab = i);
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '홈'),
            NavigationDestination(icon: Icon(Icons.search), label: '검색'),
            NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: '인물'),
            NavigationDestination(icon: Icon(Icons.tune), label: '설정'),
          ],
        ),
      );
}
