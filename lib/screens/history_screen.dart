import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/locale_service.dart';
import '../services/steno_client.dart';

/// Ultime dettature della sessione, dalla piu' recente. Serve soprattutto
/// quando l'incolla automatico e' finito nella finestra sbagliata: senza
/// questa schermata quel testo sarebbe perso.
///
/// L'elenco vive solo in memoria sul PC (vedi HISTORY_MAX_ENTRIES in
/// daemon.py) e qui arrivano solo le anteprime: toccando una voce si chiede
/// al demone di re-incollare il testo integrale, che non passa mai dal
/// telefono.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.client,
    required this.locale,
  });

  final StenoClient client;
  final LocaleService locale;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  Strings get _s => Strings(widget.locale.language);

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClientChanged);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientChanged);
    super.dispose();
  }

  void _onClientChanged() {
    if (mounted) setState(() {});
  }

  String _formatTime(DateTime at) {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.client.history;

    return Scaffold(
      appBar: AppBar(title: Text(_s.historyTitle)),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _s.historyEmpty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  leading: Icon(
                    entry.pasted ? Icons.check_circle : Icons.error_outline,
                    // l'incolla fallito e' proprio il caso per cui questa
                    // schermata esiste: va distinto a colpo d'occhio
                    color: entry.pasted
                        ? Colors.green.shade600
                        : Colors.orange.shade700,
                  ),
                  title: Text(entry.preview),
                  subtitle: Text(
                    entry.pasted
                        ? _formatTime(entry.at)
                        : '${_formatTime(entry.at)} — ${_s.historyNotPasted}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.content_paste_go),
                    tooltip: _s.historyPasteAgain,
                    onPressed: () => _pasteAgain(entry.id),
                  ),
                  onTap: () => _pasteAgain(entry.id),
                );
              },
            ),
    );
  }

  void _pasteAgain(String id) {
    widget.client.pasteHistoryEntry(id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_s.historyPasteSent),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
