/// 제조사별 "앱을 재우는 설정" 안내와 바로 열 설정 화면 표 (#18).
///
/// 판별·문구·화면 후보를 이 표 하나에 둔다. 화면(Dart)이 [vendorOf]로 고르고, 설정 열기 버튼은 고른 항목의
/// [Vendor.screens]를 Kotlin(`MainActivity.openVendorSettings`)에 넘겨 앞에서부터 열어 본다. 다 안 되면 앱 정보.
/// 판별은 Build.MANUFACTURER와 Build.BRAND를 둘 다 본다(예: 예전 Honor는 MANUFACTURER가 HUAWEI, BRAND가 HONOR).
///
/// 후보 순위 (2026-11 확인, 숫자는 각 자료 그대로)
///   국내: StatCounter 모바일 제조사(사용량) 2026-10 — Samsung 57.5%, Apple 39.31%, Xiaomi 0.61%, LG 0.44%, Vivo 0.21%
///         https://gs.statcounter.com/vendor-market-share/mobile/south-korea
///   세계 출하: IDC 3Q26 잠정 — Samsung 22.6%, Apple 22.4%, Xiaomi 12.0%, OPPO 10.0%, vivo 7.5%
///         https://www.idc.com/resource-center/press-releases/smartphone-shipments-decline-3q26/
///   세계 출하: IDC 3Q25 — Samsung 19.0%, Apple 18.2%, Xiaomi 13.5%, Transsion 9.0%, vivo 8.9% (3Q26 상위 5에서는 빠짐)
///         https://www.idc.com/?p=105705
///   세계 출하: Omdia 3Q26 — Samsung 57.8M, Apple 56.5M, Xiaomi 30.7M, OPPO(realme·OnePlus 포함) 23.4M, vivo 19.3M
///         https://www.lightreading.com/smartphones-devices/global-smartphone-shipments-fell-20-in-3q26-the-lowest-third-quarter-total-since-2013-omdia
///   보급형 지역 사용량 StatCounter 2026-10:
///     아프리카 Samsung 36.92%, Apple 16.92%, Xiaomi 8.56%, Tecno 6.09%, Honor 5.36%, Oppo 5.26%
///       https://gs.statcounter.com/vendor-market-share/mobile/africa
///     남미 Samsung 24.18%, Apple 20.77%, Xiaomi 12.83%, Motorola 11.58%, Honor 1.64%
///       https://gs.statcounter.com/vendor-market-share/mobile/south-america
///     인도 Vivo 22.06%, Oppo 16.06%, Xiaomi 14.95%, Samsung 12.17%, Realme 9.17%, Motorola 7.23%
///       https://gs.statcounter.com/vendor-market-share/mobile/india
///   → 순위: 삼성 > 샤오미(Redmi·POCO) > OPPO·realme·OnePlus > vivo·iQOO > Transsion(TECNO·Infinix·itel) > Honor > Motorola > Huawei.
///     LG·Google Pixel·Nothing 등은 기본 안내(앱 정보 › 배터리 › 제한 없음).
///
/// 설정 경로 출처: https://dontkillmyapp.com/ (samsung, xiaomi, oppo, realme, oneplus, vivo, huawei, tecno, motorola 페이지)
/// 화면 컴포넌트 출처: AutoStarter AutoStartPermissionHelper.kt
///   https://github.com/judemanutd/AutoStarter/blob/master/autostarter/src/main/java/com/judemanutd/autostarter/AutoStartPermissionHelper.kt
/// MANUFACTURER/BRAND 값 출처(기기 프로필): https://github.com/whyorean/GPlayApi/tree/master/src/main/resources ,
///   https://docs.rs/crate/gpapi/6.1.0/source/device.properties — samsung/samsung, Xiaomi/Xiaomi·Redmi, OPPO/OPPO,
///   OnePlus/OnePlus, realme·Realme, HUAWEI/HUAWEI, HUAWEI/HONOR, Motorola/Motorola, LGE/google(Nexus 5X), Google/google, Nothing/Nothing.
///   vivo·iQOO·TECNO·Infinix·itel·새 HONOR 값은 미확인 — 대소문자·꼬리말(예: "... MOBILE LIMITED")에 상관없게 낱말로 비교한다.
///
/// 실기기 확인: 샤오미(Redmi, HyperOS OS1.0)만. 나머지는 모두 실기기 미확인.
library;

class Vendor {
  const Vendor(this.key, this.names, this.title, this.body, this.button, [this.screens = const []]);

  /// 안내 키 (테스트·로그용)
  final String key;

  /// MANUFACTURER·BRAND를 낱말로 나눈 것 중 하나라도 같으면 이 제조사 (소문자)
  final List<String> names;
  final String title, body, button;

  /// 앞에서부터 열어 볼 설정 화면 (패키지, 액티비티). 비어 있거나 다 안 되면 앱 정보
  final List<(String, String)> screens;
}

/// 표 순서대로 판별한다. Honor는 Huawei보다 앞(예전 Honor는 MANUFACTURER가 HUAWEI라서 BRAND로 먼저 잡는다).
const vendors = <Vendor>[
  // 삼성 One UI: 배터리 › 백그라운드 사용 제한 › 절전 예외 앱 (dontkillmyapp: Android 11+ "Background usage limits" ›
  // "Never sleeping apps"). 화면 컴포넌트는 실기기 미확인 — 갤럭시에서 시험 필요
  Vendor('samsung', ['samsung'], '삼성 폰: 절전 예외 앱에 넣기',
      '배터리 › 백그라운드 사용 제한 › "절전 예외 앱"에 추억먹는하마를 넣어 주세요. 며칠 앱을 안 열면 잠자기 앱이 되어 정리가 멈출 수 있어요.',
      '설정 열기', [
    ('com.samsung.android.lool', 'com.samsung.android.sm.battery.ui.usage.CheckableAppListActivity'),
    ('com.samsung.android.lool', 'com.samsung.android.sm.battery.ui.BatteryActivity'),
    ('com.samsung.android.lool', 'com.samsung.android.sm.ui.battery.BatteryActivity'),
  ]),
  // 샤오미 HyperOS: 앱 정보에 자동 시작이 없고 보안 앱의 자동 시작 목록에 있다 (Redmi, HyperOS OS1.0 실기기 확인).
  // MIUI 14: 설정 › 앱 › 앱 › 앱 권한 › 백그라운드 자동 시작 (dontkillmyapp, 실기기 미확인)
  Vendor('xiaomi', ['xiaomi', 'redmi', 'poco'], '샤오미 폰: 자동 시작 켜기',
      '목록에서 추억먹는하마의 "자동 시작"을 켜 주세요. 꺼져 있으면 폰을 다시 켠 뒤 밤 정리가 깨어나지 못해요.',
      '자동 시작 설정 열기', [
    ('com.miui.securitycenter', 'com.miui.permcenter.autostart.AutoStartManagementActivity'),
  ]),
  // OPPO ColorOS·realme UI·OnePlus OxygenOS(같은 뿌리): 앱 정보 › 배터리 사용량 › 백그라운드 실행 / 자동 시작 허용,
  // realme: 설정 › 배터리 › (절전 설정 ›) 앱 배터리 관리 › 자동 실행·백그라운드 활동 허용. 화면 컴포넌트 모두 실기기 미확인
  Vendor('oppo', ['oppo', 'realme', 'oneplus'], '이 폰: 자동 실행과 백그라운드 활동 허용',
      '앱 정보 › 배터리에서 "자동 실행"과 "백그라운드 활동"을 허용해 주세요. 최근 앱 화면에서 추억먹는하마를 잠가 두면 더 좋아요.',
      '설정 열기', [
    ('com.coloros.safecenter', 'com.coloros.safecenter.permission.startup.StartupAppListActivity'),
    ('com.coloros.safecenter', 'com.coloros.safecenter.startupapp.StartupAppListActivity'),
    ('com.oppo.safe', 'com.oppo.safe.permission.startup.StartupAppListActivity'),
    ('com.oneplus.security', 'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity'),
  ]),
  // vivo Funtouch OS·iQOO: 설정 › 배터리 › 백그라운드 전력 소비 관리(또는 높은 백그라운드 전력 소비),
  // 설정 › 앱 › 자동 시작. OriginOS는 dontkillmyapp에 없음. 화면 컴포넌트 실기기 미확인
  Vendor('vivo', ['vivo', 'iqoo'], 'vivo 폰: 백그라운드 전력 사용 허용',
      '설정 › 배터리 › "백그라운드 전력 소비 관리"에서 추억먹는하마를 허용하고, "자동 시작"이 있으면 켜 주세요.',
      '설정 열기', [
    ('com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity'),
    ('com.vivo.permissionmanager', 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity'),
    ('com.iqoo.secure', 'com.iqoo.secure.ui.phoneoptimize.BgStartUpManager'),
  ]),
  // Transsion HiOS·XOS: Phone Master › 도구 › 자동 시작 관리, 설정 › 배터리 › 앱 절전 관리 끄기 (dontkillmyapp/tecno).
  // 열 수 있는 화면은 미확인이라 앱 정보로
  Vendor('transsion', ['tecno', 'infinix', 'itel'], '이 폰: 자동 시작 켜기',
      '"Phone Master" 앱 › 도구 › "자동 시작 관리"에서 추억먹는하마를 켜 주세요. 앱 정보 › 배터리가 "제한 없음"인지도 봐 주세요.',
      '앱 정보 열기'),
  // Honor MagicOS(예전 EMUI): 설정 › 배터리 › 앱 실행 › "수동 관리"로 바꾸고 스위치 모두 켜기 (dontkillmyapp/huawei의 Honor 기종).
  // 화면 컴포넌트는 EMUI 시절 것, MagicOS에서는 실기기 미확인
  Vendor('honor', ['honor'], '이 폰: 앱 실행을 직접 관리',
      '설정 › 배터리 › "앱 실행"에서 추억먹는하마를 "수동 관리"로 바꾸고 스위치를 모두 켜 주세요.',
      '설정 열기', [
    ('com.huawei.systemmanager', 'com.huawei.systemmanager.optimize.process.ProtectActivity'),
  ]),
  // Motorola: 앱 정보 › 앱 배터리 사용량 › 제한 없음, 설정 › 배터리 › 비활성 상태 배터리 개선 끄기 (dontkillmyapp/motorola).
  // 열 수 있는 전용 화면 없음
  Vendor('motorola', ['motorola'], '모토로라 폰: 배터리 제한 없음',
      '앱 정보 › 배터리에서 "제한 없음"을 골라 주세요. 설정 › 배터리에 "비활성 상태일 때 배터리 개선"이 있으면 꺼 주세요.',
      '앱 정보 열기'),
  // Huawei EMUI 8~10: 설정 › 배터리 › 앱 실행 › 수동 관리, 스위치 모두 켜기 (dontkillmyapp/huawei). 실기기 미확인
  Vendor('huawei', ['huawei'], '이 폰: 앱 실행을 직접 관리',
      '설정 › 배터리 › "앱 실행"에서 추억먹는하마를 "수동 관리"로 바꾸고 스위치를 모두 켜 주세요.',
      '설정 열기', [
    ('com.huawei.systemmanager', 'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity'),
    ('com.huawei.systemmanager', 'com.huawei.systemmanager.optimize.process.ProtectActivity'),
  ]),
];

/// 목록에 없는 폰(픽셀·LG·Nothing 등): 배터리 최적화 예외(위 카드)에 더해 앱 정보에서 한 번 더 본다
const defaultVendor = Vendor('default', [], '이 폰: 앱 정보에서 배터리 제한 풀기',
    '앱 정보 › 배터리에서 "제한 없음"을 골라 주세요. "자동 시작"이나 "백그라운드 실행"이 있으면 켜 주세요.',
    '앱 정보 열기');

/// "TECNO MOBILE LIMITED" → [tecno, mobile, limited]
Iterable<String> _words(String s) => s.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty);

/// Build.MANUFACTURER와 Build.BRAND로 안내를 고른다. 어느 것도 안 맞으면 [defaultVendor]
Vendor vendorOf(String manufacturer, [String brand = '']) {
  final words = {..._words(manufacturer), ..._words(brand)};
  for (final v in vendors) {
    if (v.names.any(words.contains)) return v;
  }
  return defaultVendor;
}
