/// Stato del demone Stenografa, ricevuto dal PC come messaggio
/// `{"type":"state","state":"..."}`. `thinking` si verifica solo dopo la
/// registrazione con un pulsante kind="ai_command": il testo dettato e'
/// stato trascritto ed e' in corso l'interpretazione tramite LLM locale.
enum DaemonState { unknown, idle, recording, transcribing, loading, thinking }

DaemonState daemonStateFromString(String? value) {
  switch (value) {
    case 'idle':
      return DaemonState.idle;
    case 'recording':
      return DaemonState.recording;
    case 'transcribing':
      return DaemonState.transcribing;
    case 'loading':
      return DaemonState.loading;
    case 'thinking':
      return DaemonState.thinking;
    default:
      return DaemonState.unknown;
  }
}

/// Stato della connessione TCP dell'app verso il demone.
enum ConnectionStatus { disconnected, connecting, connected, authFailed, error }
