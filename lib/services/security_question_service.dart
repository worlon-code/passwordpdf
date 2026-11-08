import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Predefined common security questions
const List<String> kDefaultSecurityQuestions = [
  'What was the name of your first school?',
  "What is your mother's maiden name?",
  'What was your childhood nickname?',
  'What city were you born in?',
  'What was the make of your first car or bike?',
  'What was the name of your first pet?',
  'What was your favorite childhood food?',
  'Custom question...',
];

/// Service managing the security question & answer required for viewing vault passwords
class SecurityQuestionService {
  static final SecurityQuestionService _instance = SecurityQuestionService._internal();
  factory SecurityQuestionService() => _instance;
  SecurityQuestionService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static const String _keyQuestion = 'sec_question_prompt';
  static const String _keyAnswerHash = 'sec_question_hash';
  static const String _salt = 'pdf_vault_sec_q_salt_v1';

  /// Check if the user has configured a security question
  Future<bool> isSecurityQuestionSet() async {
    final q = await _storage.read(key: _keyQuestion);
    final a = await _storage.read(key: _keyAnswerHash);
    return q != null && q.isNotEmpty && a != null && a.isNotEmpty;
  }

  /// Get the current security question text
  Future<String?> getSecurityQuestion() async {
    return _storage.read(key: _keyQuestion);
  }

  /// Save or update security question and answer
  Future<void> setSecurityQuestion(String question, String answer) async {
    final cleanQ = question.trim();
    final cleanA = answer.trim().toLowerCase();
    if (cleanQ.isEmpty || cleanA.isEmpty) {
      throw ArgumentError('Question and answer cannot be empty');
    }

    final hash = _hashAnswer(cleanA);
    await _storage.write(key: _keyQuestion, value: cleanQ);
    await _storage.write(key: _keyAnswerHash, value: hash);
  }

  /// Verify user-entered answer against stored hash
  Future<bool> verifyAnswer(String answer) async {
    final storedHash = await _storage.read(key: _keyAnswerHash);
    if (storedHash == null || storedHash.isEmpty) return false;

    final inputHash = _hashAnswer(answer.trim().toLowerCase());
    return inputHash == storedHash;
  }

  /// Delete/reset security question
  Future<void> clearSecurityQuestion() async {
    await _storage.delete(key: _keyQuestion);
    await _storage.delete(key: _keyAnswerHash);
  }

  String _hashAnswer(String normalizedAnswer) {
    final bytes = utf8.encode('$_salt:$normalizedAnswer');
    return sha256.convert(bytes).toString();
  }

  /// Show dialog to set up the security question (if empty)
  Future<bool> promptSetSecurityQuestion(BuildContext context) async {
    String selectedQuestion = kDefaultSecurityQuestions.first;
    final customQuestionController = TextEditingController();
    final answerController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isCustom = false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.security, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('Set Security Question'),
              ],
            ),
            content: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'To protect your passwords, please set a security question. This will be required whenever viewing or revealing passwords.',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    const Text('Select Question:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: selectedQuestion,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: kDefaultSecurityQuestions.map((q) {
                        return DropdownMenuItem(value: q, child: Text(q, overflow: TextOverflow.ellipsis));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            selectedQuestion = val;
                            isCustom = (val == 'Custom question...');
                          });
                        }
                      },
                    ),
                    if (isCustom) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: customQuestionController,
                        decoration: const InputDecoration(
                          labelText: 'Your Custom Question',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a question' : null,
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Text('Answer:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: answerController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Security Answer',
                        hintText: 'Case-insensitive answer',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      validator: (v) => (v == null || v.trim().length < 2) ? 'Answer must be at least 2 characters' : null,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (formKey.currentState?.validate() ?? false) {
                    final q = isCustom ? customQuestionController.text.trim() : selectedQuestion;
                    final a = answerController.text.trim();
                    await setSecurityQuestion(q, a);
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  }
                },
                child: const Text('Save Question'),
              ),
            ],
          );
        },
      ),
    );

    return result ?? false;
  }

  /// Show dialog prompting user to answer their security question to reveal/copy a password
  Future<bool> promptVerifySecurityQuestion(BuildContext context) async {
    final question = await getSecurityQuestion();
    if (question == null || question.isEmpty) return false;

    final answerController = TextEditingController();
    String? errorText;

    if (!context.mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.lock_person, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('Security Verification'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Please answer your security question to reveal or copy this password:',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Theme.of(ctx).colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.help_outline, size: 18, color: Colors.blueAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          question,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: answerController,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Your Answer',
                    border: const OutlineInputBorder(),
                    errorText: errorText,
                    isDense: true,
                  ),
                  onSubmitted: (_) async {
                    final valid = await verifyAnswer(answerController.text);
                    if (valid) {
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } else {
                      setState(() => errorText = 'Incorrect answer. Please try again.');
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final valid = await verifyAnswer(answerController.text);
                  if (valid) {
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } else {
                    setState(() => errorText = 'Incorrect answer. Please try again.');
                  }
                },
                child: const Text('Verify'),
              ),
            ],
          );
        },
      ),
    );

    return result ?? false;
  }
}
