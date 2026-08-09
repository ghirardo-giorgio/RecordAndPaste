class ConnectionSettings {
  const ConnectionSettings({
    required this.host,
    required this.port,
    required this.token,
  });

  final String host;
  final int port;
  final String token;

  bool get isComplete => host.isNotEmpty && token.isNotEmpty;
}
