part of '../main.dart';

// ───────────────────────────── 처음 실행: 개인정보 약속 → 권한과 이유 → 밤 정리 안내

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> with WidgetsBindingObserver {
  final pages = PageController();
  int step = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Status.i.start(); // 사진 보기를 허용하면 갤러리를 읽기 시작해 사진 수가 보인다
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 권한·배터리 설정 창에서 돌아오면 다시 읽는다
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Status.i.refresh(scan: Status.i.permission);
  }

  void next() {
    if (step < 2) {
      pages.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    } else {
      setPref('onboarded', '1');
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Shell()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).cardTheme.color,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(
              label: '3단계 중 ${step + 1}단계',
              child: Row(children: [
                for (var i = 0; i < 3; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(right: 6),
                    width: i == step ? 24 : 6,
                    height: 6,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), color: i == step ? cs.primary : cs.outlineVariant),
                  ),
              ]),
            ),
            Expanded(
              child: PageView(
                controller: pages,
                onPageChanged: (i) => setState(() => step = i),
                children: const [_Promise(), _Permissions(), _NightGuide()],
              ),
            ),
            const SizedBox(height: 16), // 길어서 스크롤되는 단계도 마지막 카드가 버튼에 붙지 않게
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              onPressed: next,
              child: Text(step == 0 ? '계속하기' : step == 1 ? '다음' : '알겠어요'),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(step == 0 ? '다음: 사진 보기 허용 → 밤 정리 안내' : step == 1 ? '나중에 설정에서 바꿀 수 있어요' : ' ',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head(this.title, this.body, {this.icon, this.appName = false});
  final String title, body;
  final IconData? icon;
  final bool appName; // 첫 화면 맨 위에 앱 이름을 작게 한 줄

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (appName) ...[
        const SizedBox(height: 24),
        Text('추억먹는하마', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: cs.primary)),
        const SizedBox(height: 16),
      ] else
        SizedBox(height: icon == null ? 40 : 56),
      if (icon != null) ...[
        Container(
          width: 88, height: 88,
          decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(28)),
          child: Icon(icon, size: 44, color: cs.primary),
        ),
        const SizedBox(height: 32),
      ],
      Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 26, height: 1.35)),
      const SizedBox(height: 12),
      Text(body, style: TextStyle(fontSize: 15, height: 1.6, color: cs.onSurfaceVariant)),
    ]);
  }
}

class _Promise extends StatelessWidget {
  const _Promise();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget row(IconData icon, String title, String sub) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 20, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text(sub, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              ]),
            ),
          ]),
        );
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Head('사진은 이 폰을\n떠나지 않아요', '얼굴 찾기와 장면 분석을 모두 폰 안에서 해요. 서버로 보내는 사진은 한 장도 없어요.', icon: Icons.verified_user_outlined, appName: true),
        const SizedBox(height: 32),
        row(Icons.wifi_off, '인터넷 없이도 동작', '비행기 모드에서도 검색돼요'),
        row(Icons.person_outline, '가입·로그인 없음', '설치하면 바로 시작해요'),
        row(Icons.delete_outline, '원본 사진은 그대로', '사진을 바꾸거나 지우지 않아요'),
      ]),
    );
  }
}

class _Permissions extends StatelessWidget {
  const _Permissions();

  @override
  Widget build(BuildContext context) => const SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Head('정리하려면 두 가지가\n필요해요', '왜 필요한지 먼저 알려 드릴게요.'),
          SizedBox(height: 24),
          PermissionsList(),
        ]),
      );
}

/// 권한마다 왜 필요한지 + 허용 버튼. 처음 실행과 설정 › 권한과 배터리에서 같이 쓴다
class PermissionsList extends StatelessWidget {
  const PermissionsList({super.key});

  /// 제조사가 배터리 최적화 예외와 따로 앱을 재우거나 막는 설정. 기본 안드로이드(픽셀 등)는 예외면 충분해 안내하지 않는다
  static ({String title, String body, String button})? vendorGuide(String manufacturer) {
    final m = manufacturer.toLowerCase();
    if (RegExp('xiaomi|redmi|poco').hasMatch(m)) {
      return (
        title: '샤오미 폰: 자동 시작 켜기',
        body: '목록에서 추억먹는하마의 "자동 시작"을 켜 주세요. 꺼져 있으면 폰을 다시 켠 뒤 밤 정리가 깨어나지 못해요.',
        button: '자동 시작 설정 열기',
      );
    }
    if (m == 'samsung') {
      return (
        title: '삼성 폰: 절전 예외 앱에 넣기',
        body: '배터리 › 백그라운드 사용 제한 › "절전 예외 앱"에 추억먹는하마를 넣어 주세요. 며칠 앱을 안 열면 잠자기 앱이 되어 정리가 멈출 수 있어요.',
        button: '설정 열기',
      );
    }
    if (RegExp('oppo|realme|oneplus|vivo|iqoo|huawei|honor|meizu|asus').hasMatch(m)) {
      return (
        title: '이 폰: 백그라운드 실행 허용',
        body: '앱 정보에서 배터리를 "제한 없음"으로 바꾸고, "자동 시작"이나 "백그라운드 실행 허용"이 있으면 켜 주세요.',
        button: '앱 정보 열기',
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Status.i,
        builder: (context, _) {
          final st = Status.i;
          final cs = Theme.of(context).colorScheme;
          final vendor = vendorGuide('${st.s?['manufacturer'] ?? ''}');
          Widget item(String no, String title, String why, bool done, String cta, VoidCallback onTap) => Card(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18), side: BorderSide(color: done ? cs.outlineVariant : cs.primary, width: done ? 1 : 1.5)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Container(
                        width: 40, height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                        child: Text(no, style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                      if (done) Icon(Icons.check_circle, color: cs.primary, semanticLabel: '허용됨'),
                    ]),
                    const SizedBox(height: 10),
                    Text(why, style: const TextStyle(fontSize: 14, height: 1.6)),
                    if (!done) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(foregroundColor: cs.primary, side: BorderSide(color: cs.primary, width: 1.5)),
                        onPressed: onTap,
                        child: Text(cta),
                      ),
                    ],
                  ]),
                ),
              );
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            item('1', '사진 보기 허용', '폰에 있는 사진을 읽어야 사람과 장면을 찾을 수 있어요. 정리하는 동안 진행 상황을 알림으로 보여 드려서 알림도 함께 여쭤봐요.',
                st.permission, '사진 보기 허용하기', () async {
              await channel.invokeMethod('requestPermissions');
              Status.i.refresh(scan: true);
            }),
            const SizedBox(height: 12),
            item('2', '배터리 제한 풀기', '정리는 충전 중일 때만 해요. 이 제한을 풀지 않으면 폰이 밤사이 정리를 멈춰 버려요. 낮에 배터리를 더 쓰지는 않아요.',
                st.batteryOk, '배터리 설정 열기', () => channel.invokeMethod('openBatterySettings')),
            if (vendor != null) ...[
              const SizedBox(height: 12),
              Card(
                color: cs.surfaceContainerHighest,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(vendor.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(vendor.body, style: const TextStyle(fontSize: 13, height: 1.6)),
                    TextButton(onPressed: () => channel.invokeMethod('openVendorSettings'), child: Text(vendor.button)),
                  ]),
                ),
              ),
            ],
          ]);
        },
      );
}

class _NightGuide extends StatelessWidget {
  const _NightGuide();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const steps = [
      ('자기 전에 충전기를 꽂아 두세요', '충전 중일 때만 정리해요. 충전기를 빼면 멈추고, 다음에 꽂으면 이어서 해요. 인터넷은 필요 없어요.'),
      ('폰이 알아서 정리해요', '그사이 폰을 켜서 쓰면 잠깐 멈췄다가 화면이 꺼지면 다시 해요. 폰이 뜨거워지면 식을 때까지 쉬어요.'),
      ('아침에 정리된 사진을 보세요', '정리된 만큼 홈과 검색에 바로 나와요. 다 끝나지 않았어도 다음 밤에 이어서 해요.'),
    ];
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _Head('정리는 충전 중인\n밤에 해요', '사진 분석은 폰에 꽤 힘든 일이라, 폰을 쓰지 않는 시간에 조금씩 나눠서 해요.'),
        const SizedBox(height: 28),
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 36,
                child: Column(children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: cs.primary.withValues(alpha: 0.1),
                    child: Text('${i + 1}', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700)),
                  ),
                  if (i < steps.length - 1) Expanded(child: Container(width: 2, color: cs.outlineVariant)),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(steps[i].$1, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(steps[i].$2, style: TextStyle(fontSize: 13, height: 1.55, color: cs.onSurfaceVariant)),
                  ]),
                ),
              ),
            ]),
          ),
        ListenableBuilder(
          listenable: Status.i,
          builder: (context, _) {
            final n = Status.i.photos;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n > 0 ? '이 폰의 사진 ${fmtInt(n)}장' : '이 폰의 사진', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(n > 0 ? '첫 정리는 며칠 밤 걸릴 수 있어요' : '사진이 많으면 며칠 밤 걸려요',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('그 뒤로는 새로 찍은 사진만 정리해서 금방 끝나요', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              ]),
            );
          },
        ),
      ]),
    );
  }
}

/// 설정 › 권한과 배터리
class PermissionsPage extends StatelessWidget {
  const PermissionsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('권한과 배터리')),
        body: const SingleChildScrollView(padding: EdgeInsets.fromLTRB(16, 4, 16, 24), child: PermissionsList()),
      );
}
