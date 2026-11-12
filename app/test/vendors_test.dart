// 제조사 안내 표(lib/vendors.dart): Build.MANUFACTURER·BRAND 문자열마다 맞는 안내가 나오는지 (#18)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_tracer/vendors.dart';

void main() {
  test('제조사·브랜드 문자열 → 안내 키 (대소문자 섞어도)', () {
    const cases = <(String, String, String)>[
      // (MANUFACTURER, BRAND, 기대 키)
      ('samsung', 'samsung', 'samsung'),
      ('SAMSUNG', '', 'samsung'),
      ('Xiaomi', 'Redmi', 'xiaomi'), // 이 폰(Redmi, HyperOS)
      ('Xiaomi', 'POCO', 'xiaomi'),
      ('xiaomi', 'Xiaomi', 'xiaomi'),
      ('', 'poco', 'xiaomi'),
      ('OPPO', 'OPPO', 'oppo'),
      ('realme', 'realme', 'oppo'),
      ('Realme', 'Realme', 'oppo'),
      ('OnePlus', 'OnePlus', 'oppo'),
      ('vivo', 'vivo', 'vivo'),
      ('vivo', 'iQOO', 'vivo'),
      ('TECNO MOBILE LIMITED', 'TECNO', 'transsion'),
      ('INFINIX MOBILITY LIMITED', 'Infinix', 'transsion'),
      ('itel', 'ITEL', 'transsion'),
      ('HONOR', 'HONOR', 'honor'),
      ('HUAWEI', 'HONOR', 'honor'), // 예전 Honor: 만든 곳은 HUAWEI
      ('HUAWEI', 'HUAWEI', 'huawei'),
      ('Huawei', 'huawei', 'huawei'),
      ('motorola', 'motorola', 'motorola'),
      ('Motorola', 'Motorola', 'motorola'),
      ('Google', 'google', 'default'),
      ('LGE', 'lge', 'default'),
      ('LGE', 'google', 'default'), // Nexus 5X
      ('Nothing', 'Nothing', 'default'),
      ('', '', 'default'),
    ];
    for (final (m, b, key) in cases) {
      expect(vendorOf(m, b).key, key, reason: '$m / $b');
    }
  });

  test('낱말로 비교해 다른 이름 속 글자에 걸리지 않는다', () {
    expect(vendorOf('Satellite', 'motoX').key, 'default'); // itel·moto가 글자 속에 있어도
    expect(vendorOf('HMD Global', 'Nokia').key, 'default');
  });

  test('브랜드 없이 제조사만 넘겨도 된다', () {
    expect(vendorOf('Xiaomi').key, 'xiaomi');
    expect(vendorOf('samsung').key, 'samsung');
  });

  test('샤오미 문구와 화면은 실기기(Redmi, HyperOS)에서 확인한 그대로', () {
    final v = vendorOf('Xiaomi', 'Redmi');
    expect(v.title, '샤오미 폰: 자동 시작 켜기');
    expect(v.button, '자동 시작 설정 열기');
    expect(v.screens.first, ('com.miui.securitycenter', 'com.miui.permcenter.autostart.AutoStartManagementActivity'));
  });

  test('목록에 없는 폰은 앱 정보 안내, 열 화면 없음(→ 앱 정보)', () {
    expect(defaultVendor.button, '앱 정보 열기');
    expect(defaultVendor.body, contains('제한 없음'));
    expect(defaultVendor.screens, isEmpty);
  });

  test('키가 겹치지 않고, 화면 패키지는 모두 AndroidManifest <queries>에 있다', () {
    final keys = vendors.map((v) => v.key).toList();
    expect(keys.toSet().length, keys.length);
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final v in vendors) {
      for (final (pkg, _) in v.screens) {
        expect(manifest, contains('<package android:name="$pkg"/>'), reason: '${v.key}: $pkg');
      }
    }
  });
}
