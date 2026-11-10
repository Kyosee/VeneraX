import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The approved preview palette stays local to the startup experience.
class OnboardingTheme extends StatelessWidget {
  const OnboardingTheme({super.key, required this.builder});
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final dark = base.brightness == Brightness.dark;
    final scheme = base.colorScheme.copyWith(
      primary: Color(dark ? 0xff9abaff : 0xff3767cf),
      onPrimary: Color(dark ? 0xff142645 : 0xffffffff),
      surface: Color(dark ? 0xff182235 : 0xfffcfdff),
      surfaceContainerLowest: Color(dark ? 0xff202b40 : 0xffffffff),
      surfaceContainerLow: Color(dark ? 0xff223047 : 0xfff2f5fa),
      primaryContainer: Color(dark ? 0xff273959 : 0xffedf2ff),
      onSurface: Color(dark ? 0xffe4eaf6 : 0xff18253c),
      onSurfaceVariant: Color(dark ? 0xffa6b3c9 : 0xff67758a),
      outlineVariant: Color(dark ? 0xff313e55 : 0xffe6ebf3),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return Theme(
      data: base.copyWith(
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        dividerColor: scheme.outlineVariant,
        textTheme: base.textTheme.apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            disabledBackgroundColor: Color(dark ? 0xff2b394f : 0xffe4eaf4),
            disabledForegroundColor: Color(dark ? 0xff73839e : 0xff96a3b8),
            minimumSize: const Size(0, 48),
            shape: shape,
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.onSurfaceVariant,
            backgroundColor: scheme.surfaceContainerLowest,
            side: BorderSide(color: scheme.outlineVariant),
            minimumSize: const Size(0, 46),
            shape: shape,
            textStyle: const TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          filled: true,
          fillColor: scheme.surfaceContainerLowest,
          contentPadding: const EdgeInsets.all(14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          labelStyle: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ),
      child: Builder(builder: builder),
    );
  }
}

class OnboardingBrand extends StatelessWidget {
  const OnboardingBrand({super.key, this.large = false});
  final bool large;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset(
        'assets/app_icon.png',
        width: large ? 34 : 29,
        height: large ? 34 : 29,
      ),
      SizedBox(width: large ? 10 : 7),
      Flexible(
        child: Text(
          'VeneraX',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: large ? 20 : 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

class OnboardingLanguageArt extends StatelessWidget {
  const OnboardingLanguageArt({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget tile(
      String text,
      double angle,
      double width,
      double height,
      bool first,
    ) => Transform.rotate(
      angle: angle * math.pi / 180,
      child: Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: first ? colors.primary : colors.primaryContainer,
          borderRadius: BorderRadius.circular(19),
          boxShadow: first
              ? [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: .13),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 37,
            color: first ? colors.onPrimary : colors.primary,
          ),
        ),
      ),
    );
    return SizedBox(
      height: 110,
      child: Center(
        child: SizedBox(
          width: 148,
          height: 100,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                bottom: 0,
                child: tile('文', -9, 80, 85, true),
              ),
              Positioned(
                right: 0,
                bottom: 6,
                child: tile('A', 9, 74, 78, false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OnboardingRestoreArt extends StatelessWidget {
  const OnboardingRestoreArt({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 121,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.rotate(
              angle: -math.pi / 18,
              child: Container(
                width: 122,
                height: 106,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: const BorderRadius.all(
                    Radius.elliptical(55, 50),
                  ),
                ),
              ),
            ),
            Icon(
              Icons.cloud_download_outlined,
              size: 71,
              color: colors.primary,
            ),
          ],
        ),
      ),
    );
  }
}
