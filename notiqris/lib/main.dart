import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_notification_listener/flutter_notification_listener.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initBackgroundListener();
  runApp(const MyApp());
}

/// Inisialisasi background listener agar native dapat memanggil callback
Future<void> _initBackgroundListener() async {
  await NotificationsListener.initialize(callbackHandle: notificationCallback);
}

/// Callback dari native Android (dijalankan di background isolate)
@pragma('vm:entry-point')
void notificationCallback(NotificationEvent event) {
  final port = IsolateNameServer.lookupPortByName('_notification_port');
  port?.send(event); // kirim ke main isolate untuk diproses
}

/// Aplikasi utama
class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _serviceRunning = false;
  final List<NotificationEvent> _events = [];
  ReceivePort? _receivePort;

  @override
  void initState() {
    super.initState();
    _startListening();
    _checkRunning();
  }

  /// Mendaftarkan ReceivePort untuk menerima event dari background isolate
  void _startListening() {
    _receivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(
      _receivePort!.sendPort,
      '_notification_port',
    );

    _receivePort!.listen((event) async {
      if (event is NotificationEvent) {
        setState(() {
          _events.insert(0, event);
        });

        // Kirim ke server dari UI isolate (bukan dari background isolate)
        try {
          final response = await http.post(
            Uri.parse('https://payment.kediritechnopark.com/receive'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'package': event.packageName ?? '',
              'title': event.title ?? '',
              'text': event.text ?? '',
              'timestamp': event.timestamp ?? 0,
            }),
          );

          debugPrint('Sent to server: ${response.statusCode}');
          debugPrint('Response body: ${response.body}');
        } catch (e) {
          debugPrint('Error sending to server: $e');
        }
      }
    });
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notification Listener Demo',
      home: Scaffold(
        appBar: AppBar(title: const Text('Notification Listener')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _toggleService,
          label: Text(_serviceRunning ? 'STOP' : 'START'),
          icon: Icon(_serviceRunning ? Icons.stop : Icons.play_arrow),
        ),
        body: _events.isEmpty
            ? const Center(child: Text('No notifications yet.'))
            : ListView.builder(
                itemCount: _events.length,
                itemBuilder: (_, i) {
                  final e = _events[i];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(e.packageName?[0].toUpperCase() ?? '?'),
                    ),
                    title: Text(e.title ?? ''),
                    subtitle: Text(e.text ?? ''),
                    trailing: Text(
                      e.timestamp != null
                          ? DateTime.fromMillisecondsSinceEpoch(e.timestamp!)
                              .toLocal()
                              .toString()
                              .substring(11, 19)
                          : '',
                    ),
                  );
                },
              ),
      ),
    );
  }
}
