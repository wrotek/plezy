import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduces the player's Stack layering around the right-click-for-settings
/// detector added to VideoControls.
///
/// The detector is the topmost layer but `HitTestBehavior.translucent`, which
/// reports *no* hit — so the Stack keeps testing downwards and every existing
/// opaque layer still receives its pointers. These tests pin that behaviour,
/// because it is the only reason one detector can cover a player whose pointer
/// target differs by state (full-frame tap layer when the chrome is hidden,
/// MobileSkipZones over the left/right thirds, controls overlay once shown).
///
/// Stack children are listed bottom-to-top, matching video_controls.dart.
Widget _playerLikeStack({
  required VoidCallback onSecondary,
  required VoidCallback onOuterTap,
  required ValueChanged<bool> onSkipZoneTap,
  bool locked = false,
  VoidCallback? onLockTap,
}) {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Full-frame tap layer (toggles the chrome).
          Positioned.fill(
            child: GestureDetector(
              onTap: onOuterTap,
              behavior: HitTestBehavior.opaque,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          // MobileSkipZones: opaque, left/right 35%, middle 70% vertically.
          Positioned(
            left: 0,
            top: 100,
            bottom: 100,
            width: 200,
            child: GestureDetector(
              onTap: () => onSkipZoneTap(false),
              behavior: HitTestBehavior.opaque,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          Positioned(
            right: 0,
            top: 100,
            bottom: 100,
            width: 200,
            child: GestureDetector(
              onTap: () => onSkipZoneTap(true),
              behavior: HitTestBehavior.opaque,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          // The new layer under test.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              excludeFromSemantics: true,
              onSecondaryTap: onSecondary,
              child: const SizedBox.expand(),
            ),
          ),
          // Screen lock: opaque, and sits above — so it gates the layer above
          // for free, with no explicit `_isScreenLocked` check.
          if (locked)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onLockTap,
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
        ],
      ),
    ),
  );
}

Future<void> _click(WidgetTester tester, Offset at, {required int buttons}) async {
  final gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: buttons);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  const middle = Offset(400, 300); // over the full-frame layer only
  const leftSkipZone = Offset(100, 300); // over the opaque skip zone

  testWidgets('right-click over the bare player opens settings', (tester) async {
    var secondary = false, outerTap = false;
    await tester.pumpWidget(
      _playerLikeStack(onSecondary: () => secondary = true, onOuterTap: () => outerTap = true, onSkipZoneTap: (_) {}),
    );

    await _click(tester, middle, buttons: kSecondaryButton);

    expect(secondary, isTrue);
    expect(outerTap, isFalse, reason: 'a secondary tap must not toggle the chrome');
  });

  testWidgets('right-click over an opaque skip zone still opens settings', (tester) async {
    var secondary = false;
    bool? skipped;
    await tester.pumpWidget(
      _playerLikeStack(
        onSecondary: () => secondary = true,
        onOuterTap: () {},
        onSkipZoneTap: (forward) => skipped = forward,
      ),
    );

    await _click(tester, leftSkipZone, buttons: kSecondaryButton);

    expect(secondary, isTrue, reason: 'the translucent layer sits above the opaque skip zone');
    expect(skipped, isNull, reason: 'the skip zone has no secondary recognizer, so it stays quiet');
  });

  testWidgets('a translucent layer does not swallow the taps below it', (tester) async {
    var secondary = false, outerTap = false;
    bool? skipped;
    await tester.pumpWidget(
      _playerLikeStack(
        onSecondary: () => secondary = true,
        onOuterTap: () => outerTap = true,
        onSkipZoneTap: (forward) => skipped = forward,
      ),
    );

    await _click(tester, middle, buttons: kPrimaryButton);
    expect(outerTap, isTrue, reason: 'the full-frame chrome toggle must keep working');

    await _click(tester, leftSkipZone, buttons: kPrimaryButton);
    expect(skipped, isFalse, reason: 'the backward skip zone must keep working');

    expect(secondary, isFalse, reason: 'primary taps never reach the secondary recognizer');
  });

  testWidgets('finger taps are unaffected', (tester) async {
    var secondary = false, outerTap = false;
    await tester.pumpWidget(
      _playerLikeStack(onSecondary: () => secondary = true, onOuterTap: () => outerTap = true, onSkipZoneTap: (_) {}),
    );

    await tester.tapAt(middle);
    await tester.pumpAndSettle();

    expect(outerTap, isTrue);
    expect(secondary, isFalse, reason: 'touch cannot produce a secondary button');
  });

  testWidgets('the screen lock blocks right-click', (tester) async {
    var secondary = false, lockTapped = false;
    await tester.pumpWidget(
      _playerLikeStack(
        onSecondary: () => secondary = true,
        onOuterTap: () {},
        onSkipZoneTap: (_) {},
        locked: true,
        onLockTap: () => lockTapped = true,
      ),
    );

    await _click(tester, middle, buttons: kSecondaryButton);

    expect(secondary, isFalse, reason: 'the opaque lock overlay is above, so it never reaches the path');
    expect(lockTapped, isFalse, reason: 'and the lock overlay only listens for primary taps');
  });
}
