part of '../main.dart';

// ───────────────────────────── 시작 화면(#21)
// 시스템 시작 화면(android res: LaunchTheme, Android 12+는 windowSplashScreen*)이 단색 + 가운데 120dp 아이콘을 보여 주고,
// Flutter 첫 프레임부터 이 화면이 같은 자리·크기의 아이콘을 이어 받아 그라데이션·이름·문구를 0.2초에 서서히 올린다.
// 첫 준비(화면 설정 읽기 → 홈 첫 목록)가 끝나면 0.25초 페이드로 원래 첫 화면(홈 또는 처음 안내)이 드러난다.

/// 시작 화면 색. android res/values(-night)/colors.xml과 같은 값
class LaunchColors {
  const LaunchColors._(this.top, this.center, this.bottom, this.mid, this.name, this.tagline, this.track, this.bar, this.note);

  /// 그라데이션 위(0%) · 45% · 아래(100%)
  final Color top, center, bottom;

  /// 그라데이션의 화면 세로 가운데(50%) 색 = 시스템 시작 화면 단색
  final Color mid;
  final Color name, tagline, track, bar, note;

  static const light = LaunchColors._(
    Color(0xFFFFE2BC),
    Color(0xFFFFF0DC),
    Color(0xFFFFF8EE),
    Color(0xFFFFF1DE),
    Color(0xFF1B1C1F),
    Color(0xFF3F4554),
    Color(0xFFF0D9B8),
    Color(0xFF2563EB),
    Color(0xFF4A5060),
  );
  static const dark = LaunchColors._(
    Color(0xFF2A2119),
    Color(0xFF1C1916),
    Color(0xFF141518),
    Color(0xFF1B1916),
    Color(0xFFF3F4F6),
    Color(0xFFD1D5DB),
    Color(0xFF3A3632),
    Color(0xFF6E9BFF),
    Color(0xFFB4B9C4),
  );

  /// 시스템 시작 화면과 같게 앱 설정이 아니라 폰의 다크 모드를 따른다
  static LaunchColors of(Brightness b) => b == Brightness.dark ? dark : light;
}

class Launch {
  static const name = '추억먹는하마';
  static const tagline = '가족 사진을 날짜·사람·장면으로\n알아서 정리해요';
  static const slowNote = '사진첩을 불러오고 있어요';
  static const semanticsLabel = '$name, 불러오는 중';

  // 크기(dp). 아이콘은 시스템 시작 화면과 같은 120dp, 모서리 28dp
  static const iconSize = 120.0, iconRadius = 28.0;
  static const side = 16.0; // 글자 좌우 여백
  static const nameGap = 28.0, lineGap = 10.0; // 아이콘 → 이름, 이름 → 문구
  static const barGap = 32.0, barGapTight = 10.0; // 문구 → 진행 막대(자리가 모자라면 좁힌다)
  static const noteGap = 10.0, noteGapTight = 6.0; // 막대 → 안내 글
  static const barWidth = 160.0, barHeight = 4.0;
  static const noteSize = 13.0, noteLine = 1.4;

  static const minShow = Duration(milliseconds: 600); // 너무 빨리 끝나 번쩍이기만 하지 않게
  static const fadeIn = Duration(milliseconds: 200);
  static const fadeOut = Duration(milliseconds: 250);
  static const slowAfter = Duration(seconds: 3); // 이보다 오래 걸리면 진행 막대
  static const giveUp = Duration(seconds: 20); // 신호가 끝내 안 와도 화면에 갇히지 않게

  static const iconAsset = 'assets/splash_icon.png';

  /// 홈 첫 목록(인물 칩 + 순간 첫 쪽)을 불러왔다. 실패해도 끝난 것으로 본다 — HomePage.reload가 알린다
  static final homeReady = ValueNotifier(false);
  static void markHomeReady() => homeReady.value = true;

  /// runApp 전에 풀어 둔 아이콘. 있으면 첫 프레임부터 그려진다(없으면 Image.asset이 조금 늦게 그린다)
  static ui.Image? icon;

  /// Android 11 이하: 시스템 시작 화면이 이미 그라데이션이라 처음부터 다 보이게 그린다(단색 → 그라데이션 페이드 생략)
  static bool systemGradient = false;

  /// runApp 전에(시스템 시작 화면이 보이는 동안) 아이콘을 풀고 SDK 버전을 묻는다. 늦어도 0.8초에서 끊는다
  static Future<void> prepare() async {
    Future<void> decode() async {
      try {
        final data = await rootBundle.load(iconAsset);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        icon = (await codec.getNextFrame()).image;
      } catch (_) {}
    }

    Future<void> sdk() async {
      try {
        final v = await channel.invokeMethod<int>('sdkInt');
        systemGradient = v != null && v < 31;
      } catch (_) {}
    }

    await Future.wait([decode(), sdk()]).timeout(const Duration(milliseconds: 800), onTimeout: () => const []);
  }

  /// 시작 화면 동안의 상태 막대·탐색 막대. 상태 막대는 투명(그라데이션 위쪽이 비친다), 탐색 막대는 그라데이션 맨 아래 색,
  /// 아이콘은 밝은 화면이면 어둡게·어두운 화면이면 밝게. 시스템 시작 화면(크림색 탐색 막대)에서 검게 바뀌지 않게 한다
  static SystemUiOverlayStyle barsFor(Brightness b) {
    final c = LaunchColors.of(b);
    final icons = b == Brightness.dark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: const Color(0x00000000),
      statusBarIconBrightness: icons,
      statusBarBrightness: b, // iOS용
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: c.bottom,
      systemNavigationBarDividerColor: c.bottom,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// 시작 화면이 걷힌 뒤 되돌릴 앱의 원래 막대. 앱은 막대 색을 따로 정하지 않았고, MaterialApp이 그릴 때마다 테마 밝기에 따라
  /// SystemUiOverlayStyle.dark/.light(탐색 막대 검정·흰 아이콘, 상태 막대 아이콘만)를 건다. 상태 막대 색은 거기서 정하지 않아
  /// FlutterActivity 기본(반투명 검정 0x40000000)이었으므로 그 값으로, 시작 화면이 바꾼 구분선·대비 보정도 기본으로 되돌린다
  static SystemUiOverlayStyle appBars(Brightness theme) => (theme == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
    statusBarColor: const Color(0x40000000),
    systemNavigationBarDividerColor: const Color(0x00000000),
    systemNavigationBarContrastEnforced: true,
  );

  /// 시작 화면 동안 하는 첫 준비: 화면 설정(대표 색·화면 모드·얼굴 상자)과 처음 안내를 봤는지
  static Future<bool> loadPrefs() async {
    await Look.load();
    await ShowFaces.load();
    try {
      return await pref('onboarded') == '1';
    } catch (_) {
      return false; // 채널이 없으면(테스트) 처음 안내부터
    }
  }
}

/// 시작 화면. [leaving]이 켜지면 사라지는 페이드를 하고 [onGone]을 부른다. [slow]면 진행 막대를 띄운다
class LaunchScreen extends StatefulWidget {
  const LaunchScreen({super.key, this.leaving = false, this.slow = false, this.onGone});
  final bool leaving, slow;
  final VoidCallback? onGone;

  static const iconKey = ValueKey('launch-icon');
  static const nameKey = ValueKey('launch-name');
  static const taglineKey = ValueKey('launch-tagline');
  static const barKey = ValueKey('launch-bar');
  static const noteKey = ValueKey('launch-note');

  @override
  State<LaunchScreen> createState() => _LaunchScreenState();
}

class _LaunchScreenState extends State<LaunchScreen> with TickerProviderStateMixin {
  late final appear = AnimationController(vsync: this, duration: Launch.fadeIn); // 그라데이션·이름·문구
  late final out = AnimationController(vsync: this, duration: Launch.fadeOut, value: 1); // 화면 전체 불투명도
  late final slowIn = AnimationController(vsync: this, duration: Launch.fadeIn); // 진행 막대

  @override
  void initState() {
    super.initState();
    appear.forward();
    if (widget.slow) slowIn.forward();
    if (widget.leaving) _leave();
  }

  @override
  void didUpdateWidget(LaunchScreen old) {
    super.didUpdateWidget(old);
    if (widget.slow && !old.slow) slowIn.forward();
    if (widget.leaving && !old.leaving) _leave();
  }

  void _leave() => out.reverse().then((_) {
    if (mounted) widget.onGone?.call();
  });

  @override
  void dispose() {
    appear.dispose();
    out.dispose();
    slowIn.dispose();
    super.dispose();
  }

  /// 아이콘 중심 높이. 시스템 시작 화면은 화면(디스플레이) 전체의 가운데에 아이콘을 둔다.
  /// Flutter 화면이 아래 탐색 막대만큼 짧으면(전체 화면 그리기가 아닌 Android 12~14) 디스플레이 가운데에 맞춘다
  double _centerY(BuildContext context, Size size) {
    final view = View.of(context);
    try {
      final dpr = view.devicePixelRatio;
      final display = view.display.size / dpr;
      final mine = view.physicalSize / dpr;
      final short = display.height - mine.height;
      if ((display.width - mine.width).abs() < 1 && (mine.height - size.height).abs() < 1 && short > 0 && short <= 64) {
        return display.height / 2;
      }
    } catch (_) {}
    return size.height / 2;
  }

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    final c = LaunchColors.of(brightness);
    final mq = MediaQuery.of(context);
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final gradient = Launch.systemGradient ? kAlwaysCompleteAnimation : appear;
    // 안내 글은 한 줄(maxLines 1)이라 높이를 미리 안다. 글자 그리기가 픽셀에 맞춰 올리는 만큼 올림
    final noteHeight = (mq.textScaler.scale(Launch.noteSize) * Launch.noteLine).ceilToDouble();
    // 화면 맨 위에 깔린 이 영역의 막대 모양이 매 프레임 적용된다(밑에 깔린 화면의 AppBar보다 앞선다)
    return AnnotatedRegion<SystemUiOverlayStyle>(value: Launch.barsFor(brightness), child: _body(context, c, mq, base, gradient, noteHeight));
  }

  Widget _body(BuildContext context, LaunchColors c, MediaQueryData mq, TextStyle base, Animation<double> gradient, double noteHeight) {
    return FadeTransition(
      opacity: out,
      child: Material(
        type: MaterialType.transparency,
        // TalkBack: 이 묶음 하나만 "추억먹는하마, 불러오는 중"으로 한 번 읽는다(아이콘·이름·문구는 따로 읽지 않는다)
        child: Semantics(
          container: true,
          liveRegion: true,
          label: Launch.semanticsLabel,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: c.mid), // 시스템 시작 화면과 같은 단색(첫 프레임)
              FadeTransition(
                opacity: gradient,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [c.top, c.center, c.bottom],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
              CustomMultiChildLayout(
                delegate: _LaunchLayout(centerY: _centerY(context, mq.size), safeBottom: mq.viewPadding.bottom, noteHeight: noteHeight),
                children: [
                  LayoutId(
                    id: _Part.icon,
                    child: const ExcludeSemantics(child: _LaunchIcon(key: LaunchScreen.iconKey)),
                  ),
                  LayoutId(
                    id: _Part.text,
                    child: ExcludeSemantics(
                      child: FadeTransition(
                        opacity: appear,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              Launch.name,
                              key: LaunchScreen.nameKey,
                              textAlign: TextAlign.center,
                              style: base.copyWith(fontSize: 26, fontWeight: FontWeight.w700, height: 1.3, letterSpacing: -0.4, color: c.name),
                            ),
                            const SizedBox(height: Launch.lineGap),
                            Text(
                              Launch.tagline,
                              key: LaunchScreen.taglineKey,
                              textAlign: TextAlign.center,
                              style: base.copyWith(fontSize: 16, fontWeight: FontWeight.w400, height: 1.55, color: c.tagline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 진행 막대와 안내 글은 위 묶음과 따로 놓인 층: 나타나도 아이콘·이름·문구 자리는 그대로다
                  if (widget.slow) ...[
                    LayoutId(
                      id: _Part.bar,
                      child: FadeTransition(
                        opacity: slowIn,
                        child: Semantics(
                          container: true,
                          liveRegion: true,
                          label: Launch.slowNote,
                          child: ExcludeSemantics(
                            child: _SlidingBar(key: LaunchScreen.barKey, track: c.track, color: c.bar),
                          ),
                        ),
                      ),
                    ),
                    LayoutId(
                      id: _Part.note,
                      child: ExcludeSemantics(
                        child: FadeTransition(
                          opacity: slowIn,
                          child: Text(
                            Launch.slowNote,
                            key: LaunchScreen.noteKey,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: base.copyWith(fontSize: Launch.noteSize, height: Launch.noteLine, color: c.note),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LaunchIcon extends StatelessWidget {
  const _LaunchIcon({super.key});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Launch.iconRadius),
    child: Launch.icon != null
        ? RawImage(image: Launch.icon, width: Launch.iconSize, height: Launch.iconSize, fit: BoxFit.cover, filterQuality: FilterQuality.medium)
        : Image.asset(
            Launch.iconAsset,
            width: Launch.iconSize,
            height: Launch.iconSize,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          ),
  );
}

enum _Part { icon, text, bar, note }

/// 아이콘 중심을 [centerY]에 고정하고, 이름·문구를 그 아래 28dp에 둔다. 두 자리는 진행 막대와 상관없이 정해진다.
/// 진행 막대는 문구 끝 + 32dp. 아래(탐색 막대·안전 영역 위)에 자리가 모자라면 틈을 좁히고, 그래도 모자라면 안내 글을, 그다음 막대를 숨긴다
class _LaunchLayout extends MultiChildLayoutDelegate {
  _LaunchLayout({required this.centerY, required this.safeBottom, required this.noteHeight});
  final double centerY, safeBottom, noteHeight;

  @override
  void performLayout(Size size) {
    const s = Launch.iconSize;
    final iconTop = centerY - s / 2;
    layoutChild(_Part.icon, BoxConstraints.tight(const Size(s, s)));
    positionChild(_Part.icon, Offset((size.width - s) / 2, iconTop));

    final textW = size.width - 2 * Launch.side < 0 ? 0.0 : size.width - 2 * Launch.side;
    final text = layoutChild(_Part.text, BoxConstraints(maxWidth: textW));
    final textTop = iconTop + s + Launch.nameGap;
    positionChild(_Part.text, Offset((size.width - text.width) / 2, textTop));
    if (!hasChild(_Part.bar)) return;

    final textBottom = textTop + text.height;
    final floor = size.height - safeBottom;
    var noteGap = Launch.noteGap;
    var showNote = true, showBar = true;
    double block() => Launch.barHeight + (showNote ? noteGap + noteHeight : 0);
    double fit() => textBottom + Launch.barGapTight > floor - block() ? textBottom + Launch.barGapTight : floor - block();
    var top = textBottom + Launch.barGap;
    if (top + block() > floor) {
      noteGap = Launch.noteGapTight;
      top = fit();
      if (top + block() > floor) {
        showNote = false;
        top = fit();
        if (top + block() > floor) showBar = false;
      }
    }

    final barW = Launch.barWidth < textW ? Launch.barWidth : textW;
    layoutChild(_Part.bar, BoxConstraints.tight(showBar ? Size(barW, Launch.barHeight) : Size.zero));
    positionChild(_Part.bar, Offset((size.width - barW) / 2, top));
    final note = layoutChild(_Part.note, showNote ? BoxConstraints(maxWidth: textW) : BoxConstraints.tight(Size.zero));
    positionChild(_Part.note, Offset((size.width - note.width) / 2, top + Launch.barHeight + noteGap));
  }

  @override
  bool shouldRelayout(_LaunchLayout old) => old.centerY != centerY || old.safeBottom != safeBottom || old.noteHeight != noteHeight;
}

/// 진행률을 모를 때 왔다갔다 하는 가는 막대(둥근 2dp)
class _SlidingBar extends StatefulWidget {
  const _SlidingBar({super.key, required this.track, required this.color});
  final Color track, color;

  @override
  State<_SlidingBar> createState() => _SlidingBarState();
}

class _SlidingBarState extends State<_SlidingBar> with SingleTickerProviderStateMixin {
  late final ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(Launch.barWidth, Launch.barHeight),
    painter: _BarPainter(CurvedAnimation(parent: ctl, curve: Curves.easeInOut), widget.track, widget.color),
  );
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.t, this.track, this.color) : super(repaint: t);
  final Animation<double> t;
  final Color track, color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = track);
    final w = size.width * 0.35;
    final x = (size.width - w) * t.value;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, w, size.height), r), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.track != track || old.color != color || old.t != t;
}
