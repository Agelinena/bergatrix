/// In-memory log buffer for the app.
///
/// Hooks [debugPrint] at startup so every call goes into a ring buffer
/// (default 1000 entries) that the SettingsScreen "Logs" view can render
/// without needing adb logcat — essential for diagnosing mobile issues
/// when the user isn't at a USB-attached dev machine.
///
/// Usage:
///   AppLogger.install();           // call once from main()
///   debugPrint('[stuff] happened'); // captured automatically
///
/// To consume from the UI:
///   AppLogger.instance.addListener(myCallback);
///   final entries = AppLogger.instance.entries;
library;

import 'package:flutter/foundation.dart';

/// One captured log line.
class LogEntry {
  final DateTime time;
  final String message;

  const LogEntry(this.time, this.message);

  /// `HH:mm:ss.t msg` format used by [LogsScreen]'s monospace list.
  String format() {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final t = (time.millisecond ~/ 100).toString();
    return '$h:$m:$s.$t  $message';
  }
}

class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  /// Hard cap so a runaway log loop can't OOM the device.
  static const int _maxEntries = 1000;

  final List<LogEntry> _entries = [];
  final List<VoidCallback> _listeners = [];
  bool _installed = false;

  /// Wraps [debugPrint] so every call is also captured here.  Idempotent.
  static void install() {
    if (instance._installed) return;
    instance._installed = true;
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        instance._capture(message);
      }
      original(message, wrapWidth: wrapWidth);
    };
    // Drop a marker into the buffer so the user knows the capture started.
    instance._capture('[AppLogger] capture installed');
  }

  void _capture(String message) {
    _entries.add(LogEntry(DateTime.now(), message));
    if (_entries.length > _maxEntries) {
      // Cheap O(n) trim, fine for a 1000-entry buffer.
      _entries.removeAt(0);
    }
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {/* never let a bad listener kill logging */}
    }
  }

  /// Manually add a log entry — useful for backend-side events that
  /// arrive on streams (not through debugPrint).
  void log(String message) => _capture(message);

  /// Read-only snapshot, oldest first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  void clear() {
    _entries.clear();
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  void addListener(VoidCallback fn) => _listeners.add(fn);
  void removeListener(VoidCallback fn) => _listeners.remove(fn);
}
