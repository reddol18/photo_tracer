// README용 화면 그림: 실제 화면 코드를 예시 데이터로 그려 docs/screens/*.png로 저장한다.
// 가족 사진·얼굴은 쓰지 않는다 — 사진 자리는 여기서 만든 풍경 그림, 인물은 관계 이름과 첫 글자.
// 사용(PowerShell): $env:SCREENS='1'; flutter test test/readme_screens_test.dart — 평소 flutter test에서는 건너뛴다
//   글꼴: Noto Sans KR(OFL). 기본 C:\Windows\Fonts\NotoSansKR-VF.ttf, 다른 곳이면 환경변수 SCREENS_FONT
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/main.dart';

final enabled = Platform.environment['SCREENS'] == '1';
final day = DateTime(2026, 10, 12, 15, 24).millisecondsSinceEpoch;
const dayMs = 86400000;

/// 사진 자리에 쓸 풍경 그림: 하늘·해·언덕(또는 바다)을 id마다 다른 색으로
Future<Uint8List> scene(int id, int w, int h) async {
  final r = Random(id);
  const skies = [Color(0xFFBFD7EA), Color(0xFFF6D6C3), Color(0xFFD9E4F5), Color(0xFFFCE9C9), Color(0xFFCDE7E1), Color(0xFFE6DDF2)];
  const grounds = [Color(0xFF7FA88B), Color(0xFF5E8FB8), Color(0xFFC9A77C), Color(0xFF8DB596), Color(0xFF4F7CA8), Color(0xFFB58E7A)];
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  final sky = skies[id % skies.length], ground = grounds[(id ~/ 2) % grounds.length];
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(0, h.toDouble()), [sky, Color.lerp(sky, Colors.white, 0.5)!]));
  c.drawCircle(Offset(w * (0.2 + r.nextDouble() * 0.6), h * (0.2 + r.nextDouble() * 0.15)), w * 0.07, Paint()..color = const Color(0xFFFFF4D6));
  for (var k = 0; k < 2; k++) {
    final base = h * (0.55 + k * 0.15);
    final p = Path()..moveTo(0, base);
    for (var x = 0.0; x <= w; x += w / 4) {
      p.quadraticBezierTo(x + w / 8, base - h * (0.05 + r.nextDouble() * 0.12), x + w / 4, base);
    }
    p
      ..lineTo(w.toDouble(), h.toDouble())
      ..lineTo(0, h.toDouble())
      ..close();
    c.drawPath(p, Paint()..color = Color.lerp(ground, Colors.black, k * 0.18)!);
  }
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// 얼굴 자리: 옅은 바탕에 사람 실루엣
Future<Uint8List> silhouette(int id, int s) async {
  const bgs = [Color(0xFFE7DDF3), Color(0xFFD9E7F5), Color(0xFFF5E1D9), Color(0xFFDCEFE3), Color(0xFFEFE9D6)];
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, s.toDouble(), s.toDouble()));
  final bg = bgs[id % bgs.length];
  c.drawRect(Rect.fromLTWH(0, 0, s.toDouble(), s.toDouble()), Paint()..color = bg);
  final fg = Paint()..color = Color.lerp(bg, const Color(0xFF475569), 0.45)!;
  c.drawCircle(Offset(s / 2, s * 0.4), s * 0.2, fg);
  c.drawOval(Rect.fromCenter(center: Offset(s / 2, s * 0.98), width: s * 0.8, height: s * 0.6), fg);
  final img = await rec.endRecording().toImage(s, s);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

final images = <int, Uint8List>{};
final faces = <int, Uint8List>{};

const people = [
  {'id': 1, 'name': '엄마', 'relation': null, 'birth_year': null, 'n': 1204, 'refs': 5, 'face': null},
  {'id': 2, 'name': '아빠', 'relation': null, 'birth_year': null, 'n': 986, 'refs': 4, 'face': null},
  {'id': 3, 'name': '딸', 'relation': null, 'birth_year': 2019, 'n': 3402, 'refs': 9, 'face': null},
  {'id': 4, 'name': '아들', 'relation': null, 'birth_year': 2022, 'n': 2877, 'refs': 7, 'face': null},
  {'id': 5, 'name': '할머니', 'relation': null, 'birth_year': null, 'n': 318, 'refs': 2, 'face': null},
  {'id': 6, 'name': '할아버지', 'relation': null, 'birth_year': null, 'n': 274, 'refs': 2, 'face': null},
];

Map<String, dynamic> status = {
  'photos_permission': true, 'notifications': true, 'battery_exempt': true, 'manufacturer': 'Google',
  'running': true, 'rest_why': '배터리 42.0℃', 'rest_left': 420, 'night_on': true, 'scan_phase': null, 'scan_done': 0, 'scan_total': 0,
  'photos': 9354, 'failed': 0, 'faces_done': 3120, 'segments': 812,
  'vec_needed': 1200, 'vec_done': 400, 'faces': 5021, 'reface_needed': 0, 'reface_done': 0, 'persons': 12,
};

Future<Object?> fake(MethodCall call) async {
  final a = call.arguments is Map ? call.arguments as Map : const {};
  switch (call.method) {
    case 'status':
      return status;
    case 'runs':
      return [
        {'id': 3, 'mode': 'night', 'start': day - dayMs, 'end': day - dayMs + 5 * 3600000, 'last': day - dayMs + 5 * 3600000,
         'photos': 1240, 'faces': 900, 'vectors': 300, 'rests': 2, 'max_temp': 41.5},
        {'id': 2, 'mode': 'night', 'start': day - 2 * dayMs, 'end': day - 2 * dayMs + 4 * 3600000, 'last': day - 2 * dayMs + 4 * 3600000,
         'photos': 1100, 'faces': 800, 'vectors': 260, 'rests': 1, 'max_temp': 40.9},
      ];
    case 'people':
      return people;
    case 'moments':
      final days = [0, 9, 10, 21, 33];
      final who = [[3, 1], [4], [3, 4, 2], [5, 6], [1]];
      final ns = [48, 1, 12, 23, 7];
      return [
        for (var i = 0; i < days.length; i++)
          {'id': i, 'start': day - days[i] * dayMs, 'end': day - days[i] * dayMs + (i == 0 ? dayMs : 0), 'n': ns[i],
           'covers': [for (var k = 0; k < min(3, ns[i]); k++) 10 * i + k], 'people': who[i]},
      ];
    case 'persons':
      return [for (var i = 0; i < 5; i++) {'id': 100 + i, 'n': [84, 41, 23, 12, 9][i], 'face': 900 + i, 'known': false}];
    case 'reviewQueue':
      return {'total': 37, 'items': [
        {'face': 950, 'photo': 7, 'person': 3, 'sim': 0.41, 'x': 0.42, 'y': 0.3, 'w': 0.16, 'h': 0.2, 'taken': day - 40 * dayMs},
      ]};
    case 'search':
      return {'items': [
        for (var i = 0; i < 6; i++)
          {'kind': 'segment', 'id': i, 'cover': 40 + i, 'n': [18, 9, 31, 6, 22, 4][i], 'date': day - [60, 75, 420, 440, 790, 860][i] * dayMs, 'date_source': 'exif'},
      ], 'rest': '바다', 'who': '딸', 'photos': 3402, 'words': [
        {'word': '딸', 'chosen': [3], 'cands': [{'ids': [3], 'note': '나의 딸'}]},
      ], 'hint': true};
    case 'gender':
      return null;
    case 'thumb':
    case 'photo':
      return images[(a['id'] as num).toInt() % 60];
    case 'faceThumb':
      return faces[(a['id'] as num).toInt()];
    default:
      return null; // 얼굴 조각은 없음 → 첫 글자로
  }
}

Future<void> loadFonts() async {
  final noto = Platform.environment['SCREENS_FONT'] ?? r'C:\Windows\Fonts\NotoSansKR-VF.ttf';
  final icons = '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  // 글꼴을 정하지 않은 글자(버튼 테마 등)는 시험 환경에서 'FlutterTest'로 그려진다 → 그 이름에도 같은 글꼴
  for (final (family, path) in [('Roboto', noto), ('FlutterTest', noto), ('MaterialIcons', icons)]) {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Directory('../docs/screens');
  final boundary = GlobalKey();

  setUpAll(() async {
    if (!enabled) return;
    await loadFonts();
    for (final id in [for (var i = 0; i < 60; i++) i]) {
      images[id] = await scene(id, 512, 512);
    }
    for (final id in [900, 901, 902, 903, 904]) {
      faces[id] = await silhouette(id, 160);
    }
    out.createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, fake);
  });

  Future<void> shoot(WidgetTester t, String name, Widget page, {Brightness b = Brightness.light, Future<void> Function()? act}) async {
    t.view.physicalSize = const Size(390, 844) * 2;
    t.view.devicePixelRatio = 2;
    await t.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(const Color(0xFF2563EB), b), home: page),
    ));
    await t.runAsync(() => Status.i.refresh());
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 150))); // 그림 디코딩
    }
    if (act != null) {
      await act();
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
        await t.runAsync(() => Future.delayed(const Duration(milliseconds: 150)));
      }
    }
    await t.pump();
    final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final png = await t.runAsync(() async {
      final img = await ro.toImage(pixelRatio: 2);
      return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    });
    File('${out.path}/$name.png').writeAsBytesSync(png!);
    await t.pumpWidget(const SizedBox());
    Status.i.stop();
  }

  testWidgets('README 화면 그림', (t) async {
    await shoot(t, 'onboarding', const OnboardingPage());
    await shoot(t, 'home', const Shell());
    await shoot(t, 'search', const Scaffold(body: SafeArea(child: SearchPage())), act: () async {
      await t.tap(find.text('바다에서 노는 아이'));
    });
    await shoot(t, 'people', const Scaffold(body: SafeArea(child: PeoplePage())));
    await shoot(t, 'night', const NightPage());
    await shoot(t, 'settings', const Scaffold(body: SafeArea(child: SettingsPage())), b: Brightness.dark);
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  }, skip: !enabled);
}
