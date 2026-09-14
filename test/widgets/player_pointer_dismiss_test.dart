import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduces the player's real gesture nesting around the trackpad
/// drag-to-dismiss so the arena outcome can be observed without a device.
///
/// Outermost is the dismiss detector (it wraps _buildVideoPlayer at the
/// OverlaySheetHost Builder), then the pinch-zoom scale detector, then the
/// full-frame opaque tap/long-press detector from video_controls.
Widget _playerLikeTree({
  required VoidCallback onDismiss,
  required VoidCallback onOuterTap,
  Set<PointerDeviceKind>? dismissDevices,
  bool withContentStripDrag = false,
  Set<PointerDeviceKind>? stripDevices,
  VoidCallback? onStripDrag,
}) {
  return MaterialApp(
    home: GestureDetector(
      supportedDevices: dismissDevices,
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (_) => onDismiss(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.trackpad},
          onScaleStart: (_) {},
          onScaleUpdate: (_) {},
          onScaleEnd: (_) {},
          child: MouseRegion(
            onHover: (_) {},
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: onOuterTap,
                    onLongPressStart: (_) {},
                    onLongPressEnd: (_) {},
                    behavior: HitTestBehavior.opaque,
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
                // The visible chrome: MobileVideoControls' content-strip drag
                // detector, which covers everything below the top bar. Present
                // whenever controls are shown and the item has chapters/queue.
                if (withContentStripDrag)
                  Positioned.fill(
                    child: Column(
                      children: [
                        const SizedBox(height: 80), // top bar
                        Expanded(
                          child: GestureDetector(
                            supportedDevices: stripDevices,
                            onVerticalDragStart: (_) {},
                            onVerticalDragUpdate: (_) {},
                            onVerticalDragEnd: (_) => onStripDrag?.call(),
                            behavior: HitTestBehavior.translucent,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('mouse drag down reaches the dismiss recognizer', (tester) async {
    var dismissed = false;
    var tapped = false;
    await tester.pumpWidget(
      _playerLikeTree(
        onDismiss: () => dismissed = true,
        onOuterTap: () => tapped = true,
        dismissDevices: const {PointerDeviceKind.mouse},
      ),
    );

    final gesture = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tapped, isFalse, reason: 'a drag must not register as a tap');
    expect(dismissed, isTrue, reason: 'the mouse drag should win the arena and dismiss');
  });

  testWidgets('touch drag down is ignored while the filter is mouse-only', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      _playerLikeTree(
        onDismiss: () => dismissed = true,
        onOuterTap: () {},
        dismissDevices: const {PointerDeviceKind.mouse},
      ),
    );

    final gesture = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.touch);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isFalse);
  });

  testWidgets('REPRO: visible content-strip chrome steals the mouse drag', (tester) async {
    var dismissed = false;
    var strip = false;
    await tester.pumpWidget(
      _playerLikeTree(
        onDismiss: () => dismissed = true,
        onOuterTap: () {},
        dismissDevices: const {PointerDeviceKind.mouse},
        withContentStripDrag: true,
        stripDevices: null, // as shipped: no device filter
        onStripDrag: () => strip = true,
      ),
    );

    final gesture = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(strip, isTrue, reason: 'the deeper strip recognizer wins the arena');
    expect(dismissed, isFalse, reason: 'so dismiss never fires — this is the reported bug');
  });

  testWidgets('FIX: scoping the strip drag to touch frees the mouse drag', (tester) async {
    var dismissed = false;
    var strip = false;
    await tester.pumpWidget(
      _playerLikeTree(
        onDismiss: () => dismissed = true,
        onOuterTap: () {},
        dismissDevices: const {PointerDeviceKind.mouse},
        withContentStripDrag: true,
        stripDevices: const {PointerDeviceKind.touch},
        onStripDrag: () => strip = true,
      ),
    );

    final gesture = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(strip, isFalse);
    expect(dismissed, isTrue, reason: 'mouse drag now reaches the dismiss recognizer');
  });

  testWidgets('FIX: touch still drives the content strip', (tester) async {
    var strip = false;
    await tester.pumpWidget(
      _playerLikeTree(
        onDismiss: () {},
        onOuterTap: () {},
        dismissDevices: const {PointerDeviceKind.mouse},
        withContentStripDrag: true,
        stripDevices: const {PointerDeviceKind.touch},
        onStripDrag: () => strip = true,
      ),
    );

    final gesture = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.touch);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(strip, isTrue, reason: 'swipe-up strip must keep working on touch');
  });

  testWidgets('touch drag down dismisses when touch is allowed', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      _playerLikeTree(
        onDismiss: () => dismissed = true,
        onOuterTap: () {},
        dismissDevices: null, // no device filter
      ),
    );

    final gesture = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.touch);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isTrue, reason: 'with no filter the touch drag should reach the recognizer');
  });
}
