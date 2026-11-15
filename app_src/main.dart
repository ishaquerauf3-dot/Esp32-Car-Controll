import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:wakelock_plus/wakelock_plus.dart';

const serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // app -> car
const txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // car -> app

const accent = Color(0xFF3DD6FF);
const bgColor = Color(0xFF0B1020);
const cardColor = Color(0xFF141B34);
const card2Color = Color(0xFF1B2447);

/// ------------------------------------------------------------------
/// Car controller: Bluetooth, telemetry, driving, voice, settings
/// ------------------------------------------------------------------
class Car extends ChangeNotifier {
  BluetoothDevice? dev;
  BluetoothCharacteristic? rx, tx;
  StreamSubscription? _valSub, _connSub;
  Timer? _hold, _poll, _voiceStop;
  SharedPreferences? prefs;

  bool connected = false, connecting = false;
  String error = '';
  String _buf = '';

  double v = 0, i = 0, p = 0, wh = 0;
  bool ina = true;
  int mode = 0, up = 0, speed = 200;
  List<String> modes = [];
  final List<double> hist = [];

  double vMin = 6.0, vMax = 8.4;
  int voiceMs = 1500;

  final stt.SpeechToText _stt = stt.SpeechToText();
  bool listening = false, _sttReady = false;
  String transcript = 'Say: forward, back, left, right, stop';

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    vMin = prefs!.getDouble('vmin') ?? 6.0;
    vMax = prefs!.getDouble('vmax') ?? 8.4;
    voiceMs = prefs!.getInt('voiceMs') ?? 1500;
    speed = prefs!.getInt('speed') ?? 200;
  }

  void saveSettings(double mn, double mx, int ms) {
    vMin = mn;
    vMax = mx;
    voiceMs = ms;
    prefs?.setDouble('vmin', mn);
    prefs?.setDouble('vmax', mx);
    prefs?.setInt('voiceMs', ms);
    notifyListeners();
  }

  // ---------------- scanning / connecting ----------------
  Future<void> scan() async {
    error = '';
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse
    ].request();
    try {
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    } catch (e) {
      error = 'Scan failed: $e';
      notifyListeners();
    }
  }

  Future<void> connect(BluetoothDevice d) async {
    connecting = true;
    error = '';
    notifyListeners();
    try {
      await FlutterBluePlus.stopScan();
      await d.connect(timeout: const Duration(seconds: 12));
      dev = d;
      _connSub = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _onLost();
      });
      try {
        await d.requestMtu(128);
      } catch (_) {}
      final services = await d.discoverServices();
      for (final s in services) {
        if (s.uuid == Guid(serviceUuid)) {
          for (final c in s.characteristics) {
            if (c.uuid == Guid(rxUuid)) rx = c;
            if (c.uuid == Guid(txUuid)) tx = c;
          }
        }
      }
      if (rx == null || tx == null) throw 'Car service not found';
      await tx!.setNotifyValue(true);
      _valSub = tx!.onValueReceived.listen(_onData);
      connected = true;
      connecting = false;
      modes = [];
      send('?');
      _poll = Timer.periodic(const Duration(seconds: 1), (_) {
        if (modes.isEmpty) send('?');
      });
      WakelockPlus.enable();
      notifyListeners();
    } catch (e) {
      error = 'Connection failed: $e';
      connecting = false;
      try {
        await d.disconnect();
      } catch (_) {}
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    stopMove();
    try {
      await dev?.disconnect();
    } catch (_) {}
    _onLost();
  }

  void _onLost() {
    _hold?.cancel();
    _poll?.cancel();
    _valSub?.cancel();
    _connSub?.cancel();
    if (listening) {
      listening = false;
      _stt.stop();
    }
    connected = false;
    connecting = false;
    rx = null;
    tx = null;
    modes = [];
    WakelockPlus.disable();
    notifyListeners();
  }

  // ---------------- telemetry ----------------
  void _onData(List<int> data) {
    _buf += utf8.decode(data, allowMalformed: true);
    while (_buf.contains('\n')) {
      final k = _buf.indexOf('\n');
      final line = _buf.substring(0, k).trim();
      _buf = _buf.substring(k + 1);
      if (line.isNotEmpty) _parse(line);
    }
    notifyListeners();
  }

  void _parse(String line) {
    if (line.startsWith('MODES,')) {
      modes = line.substring(6).split('|');
      return;
    }
    for (final part in line.split(',')) {
      if (part.length < 2) continue;
      final key = part[0], val = part.substring(1);
      switch (key) {
        case 'V':
          v = double.tryParse(val) ?? v;
          break;
        case 'I':
          i = double.tryParse(val) ?? i;
          break;
        case 'P':
          p = double.tryParse(val) ?? p;
          break;
        case 'W':
          wh = double.tryParse(val) ?? wh;
          break;
        case 'A':
          ina = val == '1';
          break;
        case 'M':
          mode = int.tryParse(val) ?? mode;
          break;
        case 'U':
          up = int.tryParse(val) ?? up;
          break;
      }
    }
    hist.add(p);
    if (hist.length > 80) hist.removeAt(0);
  }

  double get batteryPct => ((v - vMin) / (vMax - vMin)).clamp(0.0, 1.0);

  // ---------------- driving ----------------
  void send(String s) {
    final c = rx;
    if (c == null || !connected) return;
    c.write(utf8.encode('$s\n'), withoutResponse: true).catchError((_) {});
  }

  void setSpeed(int s) {
    speed = s;
    prefs?.setInt('speed', s);
    notifyListeners();
  }

  void startMove(String d) {
    stopMove(sendStop: false);
    _voiceStop?.cancel();
    send('$d,$speed');
    _hold = Timer.periodic(const Duration(milliseconds: 120), (_) => send('$d,$speed'));
    HapticFeedback.lightImpact();
  }

  void stopMove({bool sendStop = true}) {
    _hold?.cancel();
    _hold = null;
    if (sendStop) send('S');
  }

  void setMode(int m) {
    stopMove(sendStop: false);
    send('M,$m');
  }

  void emergencyStop() {
    _voiceStop?.cancel();
    stopMove();
    send('M,0');
    HapticFeedback.heavyImpact();
  }

  // ---------------- voice (English) ----------------
  String? _parseVoice(String t) {
    t = t.toLowerCase();
    bool h(List<String> w) => w.any(t.contains);
    if (h(['stop', 'halt', 'brake'])) return 'S';
    if (h(['back', 'reverse'])) return 'B';
    if (h(['forward', 'ahead', 'straight', 'go'])) return 'F';
    if (h(['left'])) return 'L';
    if (h(['right'])) return 'R';
    return null;
  }

  Future<void> toggleVoice() async {
    if (listening) {
      listening = false;
      await _stt.stop();
      transcript = 'Voice control stopped';
      notifyListeners();
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      transcript = 'Microphone permission denied';
      notifyListeners();
      return;
    }
    if (!_sttReady) {
      _sttReady = await _stt.initialize(
        onStatus: (s) {
          if (listening && (s == 'done' || s == 'notListening')) {
            Future.delayed(const Duration(milliseconds: 300), _listen);
          }
        },
        onError: (e) {
          if (listening) Future.delayed(const Duration(milliseconds: 500), _listen);
        },
      );
    }
    if (!_sttReady) {
      transcript = 'Speech recognition not available on this phone';
      notifyListeners();
      return;
    }
    listening = true;
    transcript = 'Listening...';
    notifyListeners();
    _listen();
  }

  void _listen() {
    if (!listening || _stt.isListening) return;
    _stt.listen(
      onResult: _onResult,
      localeId: 'en_US',
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
    );
  }

  void _onResult(dynamic r) {
    if (!r.finalResult) return;
    final words = (r.recognizedWords as String);
    final d = _parseVoice(words);
    if (d == null) {
      transcript = '"$words" - not understood';
    } else {
      transcript = '"$words"';
      _voiceStop?.cancel();
      if (d == 'S') {
        stopMove();
      } else {
        startMove(d);
        _voiceStop = Timer(Duration(milliseconds: voiceMs), () => stopMove());
      }
    }
    notifyListeners();
  }
}

final car = Car();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await car.init();
  runApp(const CarApp());
}

class CarApp extends StatelessWidget {
  const CarApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Car',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: accent,
        scaffoldBackgroundColor: bgColor,
        appBarTheme: const AppBarTheme(backgroundColor: bgColor),
      ),
      home: ListenableBuilder(
        listenable: car,
        builder: (context, _) => car.connected ? const Dashboard() : const ScanScreen(),
      ),
    );
  }
}

/// ------------------------------------------------------------------
/// Scan / connect screen
/// ------------------------------------------------------------------
class ScanScreen extends StatelessWidget {
  const ScanScreen({super.key});

  bool _isCar(ScanResult r) {
    final n = r.device.platformName + r.advertisementData.advName;
    return n.contains('ESP32') || r.advertisementData.serviceUuids.contains(Guid(serviceUuid));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ESP32 Car')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Icon(Icons.directions_car_filled, size: 72, color: accent),
              const SizedBox(height: 8),
              const Text('Connect to your car',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Power on the car, then tap Scan.\nNo phone Bluetooth pairing needed.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 16),
              StreamBuilder<bool>(
                stream: FlutterBluePlus.isScanning,
                initialData: false,
                builder: (context, snap) {
                  final scanning = snap.data ?? false;
                  return SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (scanning || car.connecting) ? null : car.scan,
                      icon: const Icon(Icons.bluetooth_searching),
                      label: Text(scanning ? 'Scanning...' : 'Scan for car'),
                    ),
                  );
                },
              ),
              if (car.connecting) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
              if (car.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(car.error, style: const TextStyle(color: Colors.redAccent)),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: StreamBuilder<List<ScanResult>>(
                  stream: FlutterBluePlus.scanResults,
                  initialData: const [],
                  builder: (context, snap) {
                    final list = (snap.data ?? []).where(_isCar).toList();
                    if (list.isEmpty) {
                      return const Center(
                          child: Text('No car found yet', style: TextStyle(color: Colors.white38)));
                    }
                    return ListView(
                      children: list
                          .map((r) => Card(
                                color: cardColor,
                                child: ListTile(
                                  leading: const Icon(Icons.bluetooth, color: accent),
                                  title: Text(r.device.platformName.isEmpty
                                      ? r.advertisementData.advName
                                      : r.device.platformName),
                                  subtitle: Text('Signal ${r.rssi} dBm'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: car.connecting ? null : () => car.connect(r.device),
                                ),
                              ))
                          .toList(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ------------------------------------------------------------------
/// Dashboard
/// ------------------------------------------------------------------
class Dashboard extends StatelessWidget {
  const Dashboard({super.key});

  Widget _metric(String label, String value, String unit) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: const TextStyle(fontSize: 11, color: Colors.white54, letterSpacing: .8)),
          const SizedBox(height: 2),
          Text.rich(TextSpan(children: [
            TextSpan(text: value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
            TextSpan(text: ' $unit', style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ])),
        ]),
      );

  String _fmtUp(int s) => '${s ~/ 60}m ${s % 60}s';

  void _settings(BuildContext context) {
    final mn = TextEditingController(text: car.vMin.toString());
    final mx = TextEditingController(text: car.vMax.toString());
    final ms = TextEditingController(text: car.voiceMs.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Settings'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: mn,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Battery empty voltage (V)')),
          TextField(
              controller: mx,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Battery full voltage (V)')),
          TextField(
              controller: ms,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Voice move time (ms)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              car.saveSettings(double.tryParse(mn.text) ?? car.vMin,
                  double.tryParse(mx.text) ?? car.vMax, int.tryParse(ms.text) ?? car.voiceMs);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pct = car.batteryPct;
    final batColor = pct < .2 ? Colors.redAccent : (pct < .45 ? Colors.orangeAccent : const Color(0xFF2EE59D));
    final auto = car.modes.isNotEmpty && car.mode != 0;

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.circle, size: 10, color: Color(0xFF2EE59D)),
          SizedBox(width: 8),
          Text('Connected'),
        ]),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () => _settings(context)),
          IconButton(icon: const Icon(Icons.bluetooth_disabled), onPressed: car.disconnect),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(14), children: [
          // ---- power card ----
          Card(
            color: cardColor,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                Row(children: [
                  _metric('Voltage', car.v.toStringAsFixed(2), 'V'),
                  _metric('Current', car.i.toStringAsFixed(0), 'mA'),
                  _metric('Power', car.p.toStringAsFixed(2), 'W'),
                ]),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                      value: car.ina ? pct : 0, minHeight: 10, color: batColor, backgroundColor: card2Color),
                ),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Battery ${car.ina ? (pct * 100).round() : '--'}%',
                      style: const TextStyle(fontSize: 12, color: Colors.white60)),
                  Text('Energy ${car.wh.toStringAsFixed(3)} Wh',
                      style: const TextStyle(fontSize: 12, color: Colors.white60)),
                  Text('Up ${_fmtUp(car.up)}', style: const TextStyle(fontSize: 12, color: Colors.white60)),
                ]),
                const SizedBox(height: 8),
                SizedBox(height: 70, width: double.infinity, child: CustomPaint(painter: Spark(List.of(car.hist)))),
                if (!car.ina)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('INA219 sensor not found - check wiring',
                        style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                  ),
              ]),
            ),
          ),
          // ---- control card ----
          Card(
            color: cardColor,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                if (car.modes.isEmpty)
                  const Text('Loading modes...', style: TextStyle(color: Colors.white54))
                else
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      segments: [for (int k = 0; k < car.modes.length; k++) ButtonSegment(value: k, label: Text(car.modes[k]))],
                      selected: {car.mode.clamp(0, car.modes.length - 1)},
                      onSelectionChanged: (s) => car.setMode(s.first),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  const Text('Speed', style: TextStyle(color: Colors.white60)),
                  Expanded(
                    child: Slider(
                      min: 80,
                      max: 255,
                      divisions: 35,
                      value: car.speed.toDouble().clamp(80, 255),
                      onChanged: (x) => car.setSpeed(x.round()),
                    ),
                  ),
                  Text('${(car.speed / 2.55).round()}%'),
                ]),
                Opacity(
                  opacity: auto ? .35 : 1,
                  child: IgnorePointer(
                    ignoring: auto,
                    child: Column(children: [
                      HoldButton(icon: Icons.keyboard_arrow_up, onDown: () => car.startMove('F'), onUp: car.stopMove),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        HoldButton(icon: Icons.keyboard_arrow_left, onDown: () => car.startMove('L'), onUp: car.stopMove),
                        const SizedBox(width: 10),
                        const SizedBox(width: 92, height: 92),
                        const SizedBox(width: 10),
                        HoldButton(icon: Icons.keyboard_arrow_right, onDown: () => car.startMove('R'), onUp: car.stopMove),
                      ]),
                      HoldButton(icon: Icons.keyboard_arrow_down, onDown: () => car.startMove('B'), onUp: car.stopMove),
                    ]),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                    onPressed: car.emergencyStop,
                    child: const Text('STOP', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
            ),
          ),
          // ---- voice card ----
          Card(
            color: cardColor,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: car.listening ? const Color(0xFF2EE59D) : card2Color,
                        foregroundColor: car.listening ? Colors.black : Colors.white),
                    onPressed: auto ? null : car.toggleVoice,
                    icon: Icon(car.listening ? Icons.mic : Icons.mic_none),
                    label: Text(car.listening ? 'Listening... tap to stop' : 'Start Voice Control'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(car.transcript, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Press-and-hold button
class HoldButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onDown, onUp;
  const HoldButton({super.key, required this.icon, required this.onDown, required this.onUp});
  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  bool pressed = false;
  void _up() {
    if (pressed) {
      setState(() => pressed = false);
      widget.onUp();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        setState(() => pressed = true);
        widget.onDown();
      },
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: Container(
        width: 92,
        height: 92,
        margin: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: pressed ? accent : card2Color,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Icon(widget.icon, size: 52, color: pressed ? const Color(0xFF04202A) : Colors.white),
      ),
    );
  }
}

class Spark extends CustomPainter {
  final List<double> d;
  Spark(this.d);
  @override
  void paint(Canvas c, Size s) {
    if (d.length < 2) return;
    double m = 1;
    for (final x in d) {
      if (x > m) m = x;
    }
    final path = Path();
    for (int k = 0; k < d.length; k++) {
      final x = k / (d.length - 1) * s.width;
      final y = s.height - 4 - (d[k] / m) * (s.height - 8);
      if (k == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    c.drawPath(fill, Paint()..color = const Color(0x1F3DD6FF));
    c.drawPath(
        path,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(Spark old) => true;
}
