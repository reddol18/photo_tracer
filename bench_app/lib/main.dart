import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 0단계 속도 측정 앱. 실제 측정은 네이티브(Kotlin) 엔진이 하고, 화면은 진행 로그만 보여 준다.
void main() => runApp(const BenchApp());

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PT 벤치',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: const BenchPage(),
      );
}

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  static const _channel = MethodChannel('bench');
  final _log = <String>[];
  String _dir = '';
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') _add(call.arguments as String);
    });
    _init();
  }

  Future<void> _init() async {
    final dir = await _channel.invokeMethod<String>('benchDir') ?? '';
    setState(() => _dir = dir);
    if (await _channel.invokeMethod<bool>('autorun') ?? false) _run();
  }

  void _add(String line) => setState(() {
        _log.insert(0, line);
        if (_log.length > 300) _log.removeLast();
      });

  Future<void> _run() async {
    setState(() => _running = true);
    _add('측정 시작');
    try {
      final path = await _channel.invokeMethod<String>('run');
      _add('결과 저장: $path');
    } on PlatformException catch (e) {
      _add('오류: ${e.message}');
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Photo Tracer 속도 측정')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('사진·모델 폴더: $_dir', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? '측정 중…' : '측정 시작'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [for (final line in _log) Text(line, style: const TextStyle(fontSize: 12))],
              ),
            ),
          ]),
        ),
      );
}
