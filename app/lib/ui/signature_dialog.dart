import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/auth_store.dart';
import '../data/env.dart';

/// Signature gate — shown before issuing any document (receipt, invoice
/// payment, sale, MILS log). Verifies the user's Signature Passcode.
/// Returns the signed-in user on success, null on cancel/failure.
Future<StaffUser?> confirmSignature(BuildContext context) async {
  final auth = AuthStore.instance;
  if (Env.signatureGateDisabled) {
    // No pop-up at all: the user is treated as signed.
    auth.lastVerifiedPasscode = auth.lastVerifiedPasscode ?? '';
    return auth.current;
  }
  final passcode = TextEditingController();
  String? error;

  // Decode the stored signature ONCE, defensively: a malformed/legacy
  // signature value must never throw inside the dialog's build method.
  Uint8List? sigBytes;
  final storedSig = auth.current?.signaturePng;
  if (storedSig != null && storedSig.isNotEmpty) {
    try {
      final raw = storedSig.startsWith('data:')
          ? Uri.parse(storedSig).data?.contentAsBytes()
          : null;
      sigBytes = raw ?? base64Decode(storedSig.split(',').last);
    } catch (_) {
      sigBytes = null;
    }
  }

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
            if (sigBytes != null) ...[
              const SizedBox(height: 10),
              Image.memory(sigBytes, height: 44, alignment: Alignment.centerLeft),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: passcode,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Signature passcode',
                errorText: error,
                helperText: auth.isCeo
                    ? 'CEO default: 093618 — rotate it in Settings → Account'
                    : null,
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
