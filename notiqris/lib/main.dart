import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_notification_listener/flutter_notification_listener.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

import 'login_page.dart';

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
    return Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}


/// Aplikasi utama
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _serviceRunning = false;
  final List<NotificationEvent> _events = [];
  ReceivePort? _receivePort;
  IO.Socket? socket;

  @override
  void initState() {
    super.initState();
    _startListening();
    _checkRunning();
    _connectToSocket();
  }

  Future<void> _connectToSocket() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    socket = IO.io('https://payment.kediritechnopark.com', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });

    socket!.connect();

    socket!.onConnect((_) {
      print('connected');
      socket!.emit('sign', {'token': token, 'socket_id': socket!.id});
    });
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

      final text = event.text?.toLowerCase() ?? '';
      final keywords = ['qr', 'qris', 'rp', 'transaksi', 'transaction'];

      // Cek apakah teks mengandung kata kunci
      final containsKeyword = keywords.any((keyword) => text.contains(keyword));
      if (!containsKeyword) return;

      // Deteksi angka nominal dari teks (misal Rp12.500 atau 100.000,00)
      final regex = RegExp(r'(\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?)');
      final match = regex.firstMatch(text);
      String? value;

      if (match != null) {
        // Ambil angka dan hilangkan semua karakter non-digit
        value = match.group(0)?.replaceAll(RegExp(r'[^\d]'), '');
      }

      // Kirim ke server
      try {
        final response = await http.post(
          Uri.parse('https://payment.kediritechnopark.com/receive'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'package': event.packageName ?? '',
            'title': event.title ?? '',
            'text': event.text ?? '',
            'timestamp': event.timestamp ?? 0,
            'value': value ?? '',
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
    socket?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
    );
 
  }
}
