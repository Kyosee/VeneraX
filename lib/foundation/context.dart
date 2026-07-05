import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';

import 'app_page_route.dart';

extension Navigation on BuildContext {
  void pop<T>([T? result]) {
    if(mounted) {
      Navigator.of(this).pop(result);
    }
  }

  bool canPop() {
    return Navigator.of(this).canPop();
  }

  Future<T?> to<T>(Widget Function() builder,) {
    return Navigator.of(this).push<T>(AppPageRoute(
        builder: (context) => builder()));
  }

  Future<void> toReplacement<T>(Widget Function() builder) {
    return Navigator.of(this).pushReplacement(AppPageRoute(
        builder: (context) => builder()));
  }

  // Aspect-scoped MediaQuery reads: MediaQuery.of would subscribe the caller
  // to EVERY aspect, so all of these widgets rebuilt on each frame of the
  // keyboard inset animation — a large part of the Android IME jank (#107).
  double get width => MediaQuery.sizeOf(this).width;

  double get height => MediaQuery.sizeOf(this).height;

  EdgeInsets get padding => MediaQuery.paddingOf(this);

  EdgeInsets get viewInsets => MediaQuery.viewInsetsOf(this);

  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  Brightness get brightness => Theme.of(this).brightness;

  bool get isDarkMode => brightness == Brightness.dark;

  void showMessage({required String message}) {
    showToast(message: message, context: this);
  }

  Color useBackgroundColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 100 : 800]!;
  }

  Color useTextColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 800 : 100]!;
  }
}
