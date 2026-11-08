import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/components/pattern_lock.dart';
import 'package:venera/utils/app_lock.dart';
import 'package:venera/utils/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.onSuccessfulAuth});

  /// True while the lock screen pushed over the running app is up. Set by the
  /// pusher, not from State: the page isn't built while the app is hidden.
  static bool isActive = false;

  final void Function()? onSuccessfulAuth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _localAuth = LocalAuthentication();
  bool _authenticating = false;
  bool _authenticated = false;
  String? _authError;

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          SchedulerBinding.instance.lifecycleState !=
              AppLifecycleState.paused) {
        // Only biometric mode auto-prompts; code/pattern modes wait for input.
        if (AppLock.type == AppLockType.biometric) {
          _biometricAuth();
        }
      }
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          SystemNavigator.pop();
        }
      },
      child: Material(
        child: Center(
          child: switch (AppLock.type) {
            AppLockType.biometric => _buildBiometric(),
            AppLockType.pin => _buildCodeEntry(isPin: true),
            AppLockType.password => _buildCodeEntry(isPin: false),
            AppLockType.pattern => _buildPatternEntry(),
          },
        ),
      ),
    );
  }

  Widget _buildBiometric() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.security, size: 36),
        const SizedBox(height: 16),
        Text("Authentication Required".tl),
        if (_authError != null) ...[
          const SizedBox(height: 8),
          Text(_authError!, style: TextStyle(color: context.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _authenticating || _authenticated ? null : _biometricAuth,
          child: Text("Continue".tl),
        ),
      ],
    );
  }

  // ---- PIN / password ----

  final _codeController = TextEditingController();
  String? _codeError;

  Widget _buildCodeEntry({required bool isPin}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 36),
          const SizedBox(height: 16),
          Text(
            isPin ? "Enter PIN".tl : "Enter Password".tl,
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: TextField(
              controller: _codeController,
              autofocus: true,
              obscureText: true,
              keyboardType: isPin ? TextInputType.number : TextInputType.text,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                errorText: _codeError,
              ),
              onSubmitted: (_) => _verifyCode(),
              onChanged: (_) {
                if (_codeError != null) setState(() => _codeError = null);
              },
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _verifyCode, child: Text("Unlock".tl)),
        ],
      ),
    );
  }

  void _verifyCode() {
    if (AppLock.verify(_codeController.text)) {
      widget.onSuccessfulAuth?.call();
    } else {
      setState(() => _codeError = "Incorrect".tl);
    }
  }

  // ---- pattern ----

  bool _patternError = false;

  Widget _buildPatternEntry() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.pattern, size: 36),
        const SizedBox(height: 16),
        Text(
          _patternError ? "Incorrect".tl : "Draw pattern to unlock".tl,
          style: TextStyle(
            fontSize: 16,
            color: _patternError ? context.colorScheme.error : null,
          ),
        ),
        const SizedBox(height: 24),
        PatternLock(
          dimByDefault: _patternError,
          onComplete: (pattern) {
            if (AppLock.verify(patternToString(pattern))) {
              widget.onSuccessfulAuth?.call();
            } else {
              setState(() => _patternError = true);
            }
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    if (_authenticating) {
      _localAuth.stopAuthentication().catchError((Object _) => false);
    }
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _biometricAuth() async {
    if (!mounted || _authenticating || _authenticated) return;
    setState(() {
      _authenticating = true;
      _authError = null;
    });
    try {
      final supported = await _localAuth.isDeviceSupported();
      if (!mounted) return;
      if (!supported) {
        _authError = "Biometrics not supported".tl;
        return;
      }
      final authorized = await _localAuth.authenticate(
        localizedReason: "Please authenticate to continue".tl,
      );
      if (mounted && authorized) {
        _authenticated = true;
        widget.onSuccessfulAuth?.call();
      }
    } catch (_) {
      _authError = "Authentication failed".tl;
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }
}
