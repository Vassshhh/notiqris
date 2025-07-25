import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_notification_listener/flutter_notification_listener.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;

import 'login_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initBackgroundListener();
  runApp(const MyApp());
}

Future<void> _initBackgroundListener() async {
  await NotificationsListener.initialize(callbackHandle: notificationCallback);
}

@pragma('vm:entry-point')
void notificationCallback(NotificationEvent event) {
  final port = IsolateNameServer.lookupPortByName('_notification_port');
  port?.send(event);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notiqris',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: AuthWrapper(),
      routes: {
        '/home': (context) => HomePage(),
        '/login': (context) => LoginPage(),
      },
    );
  }
}

class AuthWrapper extends StatefulWidget {
  @override
  _AuthWrapperState createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  @override
  void initState() {
    super.initState();
    _checkToken();
  }

  Future<void> _checkToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token != null) {
      Navigator.of(context).pushReplacementNamed('/home');
    } else {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class MyNotificationEvent extends NotificationEvent {
  final dynamic rawData;

  MyNotificationEvent({
    required int id,
    required String packageName,
    required String title,
    required String text,
    int? timestamp,
    this.rawData,
  }) : super(
          id: id,
          packageName: packageName,
          title: title,
          text: text,
          timestamp: timestamp,
        );

  factory MyNotificationEvent.fromNotificationEvent(NotificationEvent event) {
    return MyNotificationEvent(
      id: event.id!,
      packageName: event.packageName!,
      title: event.title!,
      text: event.text!,
      timestamp: event.timestamp,
      rawData: event.raw,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _serviceRunning = false;
  final List<MyNotificationEvent> _events = [];
  ReceivePort? _receivePort;
  IO.Socket? socket;

  @override
  void initState() {
    super.initState();
    _checkRunning();
    _startListening();
    _checkToken();
  }

  Future<void> _checkToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token != null) {
      await _connectToSocket(token);
    } else {
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/login');
      }
    }
  }

  Future<void> _connectToSocket(String token) async {
    socket = IO.io('https://payment.kediritechnopark.com', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });

    socket!.connect();

    socket!.onConnect((_) {
      print('Connected to socket.io');
      socket!.emit('sign', {'token': token, 'socket_id': socket!.id});
    });

    socket!.onError((err) {
      print('Socket error: $err');
    });
  }

  void _startListening() {
    _receivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(
      _receivePort!.sendPort,
      '_notification_port',
    );

    _receivePort!.listen((event) async {
      if (event is! NotificationEvent) return;

      debugPrint('===== NOTIFIKASI MASUK =====');
      debugPrint('Package    : ${event.packageName}');
      debugPrint('Title      : ${event.title}');
      debugPrint('Text       : ${event.text}');
      debugPrint('Extras     : ${event.raw}');
      debugPrint('=============================');

      final now = DateTime.now();
      final timeLabel = '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}]';
      final Map<String, dynamic> rawDataMap = (event.raw is Map)
          ? Map<String, dynamic>.from(event.raw as Map)
          : {};
      final extractedLines = extractLinesFromExtras(rawDataMap);
      if (extractedLines.isEmpty && event.text != null) {
        extractedLines.add(event.text!.trim());
      }
      final labeledLines = extractedLines.map((e) => '$timeLabel $e').toList();
      final fullText = labeledLines.join('\n');

      // Cek apakah mengandung keyword dan kirim POST
      final keywords = ['qr', 'qris', 'rp', 'transaksi', 'transaction'];
      final matchesKeyword = extractedLines.any((line) =>
          keywords.any((keyword) => line.toLowerCase().contains(keyword)));

      if (matchesKeyword) {
        final value = extractedLines.join(' ');
        try {
          final response = await http.post(
            Uri.parse('https://payment.kediritechnopark.com/receive'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'package': event.packageName ?? '',
              'title': event.title ?? '',
              'text': extractedLines.join('\n'),
              'timestamp': event.timestamp ?? 0,
              'value': value,
            }),
          );

          debugPrint('✅ Dikirim ke endpoint dengan status: ${response.statusCode}');
        } catch (e) {
          debugPrint('❌ Gagal kirim data: $e');
        }
      }

      setState(() {
        final existingIndex = _events.indexWhere((e) =>
            e.packageName == event.packageName && e.title == event.title);

        if (existingIndex != -1) {
          final existingEvent = _events[existingIndex];
          final oldLines = (existingEvent.text ?? '').split('\n').toSet();
          final newLines = labeledLines.toSet().difference(oldLines);
          if (newLines.isNotEmpty) {
            final mergedText = (oldLines.union(newLines)).join('\n');
            _events[existingIndex] = MyNotificationEvent(
              id: existingEvent.id ?? 0,
              packageName: existingEvent.packageName ?? '',
              title: existingEvent.title ?? '',
              text: mergedText,
              timestamp: event.timestamp ?? existingEvent.timestamp,
              rawData: rawDataMap,
            );
          }
        } else {
          _events.insert(
            0,
            MyNotificationEvent(
              id: event.id ?? 0,
              packageName: event.packageName ?? '',
              title: event.title ?? '',
              text: fullText,
              timestamp: event.timestamp,
              rawData: rawDataMap,
            ),
          );
        }
      });
    });
  }

  List<String> extractLinesFromExtras(Map<String, dynamic>? extras) {
    if (extras == null) return [];
    final linesRaw = extras['android.textLines'];
    if (linesRaw is List) {
      return linesRaw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    }
    return [];
  }

  Future<void> _checkRunning() async {
    final running = await NotificationsListener.isRunning;
    setState(() {
      _serviceRunning = running ?? false;
    });
  }

  Future<void> _toggleService() async {
    if (!_serviceRunning) {
      final hasPermission = await NotificationsListener.hasPermission ?? false;
      if (!hasPermission) {
        await NotificationsListener.openPermissionSettings();
        return;
      }
      await NotificationsListener.startService();
    } else {
      await NotificationsListener.stopService();
    }
    _checkRunning();
  }

  @override
  void dispose() {
    if (_receivePort != null) {
      IsolateNameServer.removePortNameMapping('_notification_port');
      _receivePort!.close();
    }
    socket?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Listener')),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            onPressed: _toggleService,
            label: Text(_serviceRunning ? 'STOP' : 'START'),
            icon: Icon(_serviceRunning ? Icons.stop : Icons.play_arrow),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            onPressed: () {
              debugPrint('===== SEMUA NOTIFIKASI =====');
              for (final e in _events) {
                debugPrint('📌 ${e.title} (${e.packageName})');
                debugPrint('Text: ${e.text ?? ''}');
                debugPrint('Raw: ${e.rawData ?? ''}');
              }
              debugPrint('============================');
            },
            label: const Text('Print All'),
            icon: const Icon(Icons.bug_report),
            backgroundColor: Colors.orange,
          ),
        ],
      ),
      body: _events.isEmpty
          ? const Center(child: Text('No notifications yet.'))
          : ListView.builder(
              itemCount: _events.length,
              itemBuilder: (_, i) {
                final e = _events[i];
                final formattedTime = e.timestamp != null
                    ? DateTime.fromMillisecondsSinceEpoch(e.timestamp!)
                        .toLocal()
                        .toString()
                        .substring(11, 19)
                    : '';
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.title ?? ''} (${e.packageName})',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${e.text ?? ''}\nRaw Data: ${jsonEncode(e.rawData)}',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Text(
                          formattedTime,
                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
