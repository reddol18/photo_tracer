import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

part 'ui/common.dart';
part 'ui/onboarding.dart';
part 'ui/home.dart';
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
  await Look.load();
  final onboarded = await pref('onboarded') == '1';
  runApp(PhotoTracerApp(onboarded: onboarded));
}

class PhotoTracerApp extends StatelessWidget {
  const PhotoTracerApp({super.key, required this.onboarded});
  final bool onboarded;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: Look.current,
        builder: (context, look, _) => MaterialApp(
          title: 'Photo Tracer',
          theme: buildTheme(look.accent, Brightness.light),
          darkTheme: buildTheme(look.accent, Brightness.dark),
          themeMode: look.mode,
          scrollBehavior: const _FastScroll(),
          home: onboarded ? const Shell() : const OnboardingPage(),
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 설정 화면에서 돌아오면 권한 상태를 다시 읽고, 새 사진이 있나 갤러리를 다시 본다
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Status.i.refresh(scan: true);
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
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '홈'),
            NavigationDestination(icon: Icon(Icons.search), label: '검색'),
            NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: '인물'),
            NavigationDestination(icon: Icon(Icons.tune), label: '설정'),
          ],
        ),
      );
}
