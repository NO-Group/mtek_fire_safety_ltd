import 'package:flutter/material.dart';

import '../data/auth_store.dart';

/// Signature gate — shown before issuing any document (receipt, invoice
/// payment, sale, MILS log). Verifies the user's Signature Passcode.
/// Returns the signed-in user on success, null on cancel/failure.
Future<StaffUser?> confirmSignature(BuildContext context) async {
  final auth = AuthStore.instance;
  final passcode = TextEditingController();
  String? error;

  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.draw_outlined, size: 22),
            SizedBox(width: 8),
            Text('Sign to issue'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This document will be digitally signed by ${auth.current?.name}.',
              style: const TextStyle(color: Colors.grey),
            ),
            if (auth.current?.signaturePng != null) ...[
              const SizedBox(height: 10),
              Image.memory(
                // stored as data URL; strip the prefix for Image.memory
                Uri.parse(auth.current!.signaturePng!).data!.contentAsBytes(),
                height: 44,
                alignment: Alignment.centerLeft,
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: passcode,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Signature passcode',
                errorText: error,
                prefixIcon: const Icon(Icons.password_outlined),
              ),
              onSubmitted: (_) => setState(() {}),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              // verified SERVER-SIDE when the backend is configured
              // (bcrypt against profiles.sig_passcode_hash); local fallback
              // keeps the app usable offline.
              final ok = await auth.verifySignatureAny(passcode.text);
              if (!context.mounted) return;
              if (ok) {
                Navigator.pop(context, true);
              } else {
                setState(() => error = 'Signature passcode does not match');
              }
            },
            child: const Text('Sign & issue'),
          ),
        ],
      ),
    ),
  );

  return (ok ?? false) ? auth.current : null;
}
