/// Shared types for the Cast service (platform-agnostic).
library;

/// A Chromecast device discovered via mDNS.
class CastDevice {
  final String name;
  final String host;
  final int port;

  const CastDevice({required this.name, required this.host, required this.port});

  @override
  String toString() => 'CastDevice($name @ $host:$port)';
}

/// Events emitted by the CastService.
sealed class CastServiceEvent {
  const CastServiceEvent();
}

class CastEventConnecting extends CastServiceEvent {
  const CastEventConnecting();
}

class CastEventConnected extends CastServiceEvent {
  const CastEventConnected();
}

class CastEventDisconnected extends CastServiceEvent {
  const CastEventDisconnected();
}

class CastEventError extends CastServiceEvent {
  final String message;
  const CastEventError(this.message);
}

class CastEventMediaStatus extends CastServiceEvent {
  final Map<String, dynamic> status;
  const CastEventMediaStatus(this.status);
}
