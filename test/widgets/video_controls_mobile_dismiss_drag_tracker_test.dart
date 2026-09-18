import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/video_controls/helpers/mobile_dismiss_drag_tracker.dart';
import 'package:plezy/widgets/video_controls/helpers/mobile_edge_adjustment_tracker.dart';

Duration _ms(int ms) => Duration(milliseconds: ms);

/// Drives one finger straight down in 20 px steps, 16 ms apart (1250 px/s).
List<MobileDismissDragEvent> _dragDown(MobileDismissDragTracker tracker, {int pointer = 1, int steps = 10}) {
  const start = Offset(400, 300);
  final events = <MobileDismissDragEvent>[tracker.pointerDown(pointer, start, _ms(0), canStart: true)];
  for (var i = 1; i <= steps; i++) {
    events.add(tracker.pointerMove(pointer, start + Offset(0, 20.0 * i), _ms(16 * i)));
  }
  events.add(tracker.pointerUp(pointer, start + Offset(0, 20.0 * steps), _ms(16 * steps)));
  return events;
}

void main() {
  // testWidgets, not test: VelocityTracker reads the test binding's clock,
  // which only runs inside a widget test.
  group('MobileDismissDragTracker', () {
    testWidgets('a straight downward swipe engages past the slop and follows the finger', (tester) async {
      final events = _dragDown(MobileDismissDragTracker());
      final updates = events.where((e) => e.type == MobileDismissDragEventType.update).map((e) => e.offset).toList();

      expect(updates.first, 0.0, reason: 'engages at 20 px, measured from there — no jump by the slop');
      expect(updates.last, 180.0);
      expect(updates, orderedEquals([...updates]..sort()), reason: 'offset only grows on a steady drag');
      expect(events.last.type, MobileDismissDragEventType.ended);
      expect(events.last.velocity, greaterThan(500));
    });

    testWidgets('the offset never goes negative when the finger comes back above the start', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: true);
      tracker.pointerMove(1, const Offset(400, 340), _ms(16));
      final back = tracker.pointerMove(1, const Offset(400, 200), _ms(32));
      expect(back.type, MobileDismissDragEventType.update);
      expect(back.offset, 0.0);
    });

    testWidgets('an upward start is the content strip — rejected for the whole touch', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: true);
      expect(tracker.pointerMove(1, const Offset(400, 270), _ms(16)).type, MobileDismissDragEventType.none);
      // Turning round and going down must not revive it.
      expect(tracker.pointerMove(1, const Offset(400, 500), _ms(32)).type, MobileDismissDragEventType.none);
      expect(tracker.pointerUp(1, const Offset(400, 500), _ms(48)).type, MobileDismissDragEventType.none);
    });

    testWidgets('a horizontal start (scrubbing, skip swipes) is rejected', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: true);
      tracker.pointerMove(1, const Offset(440, 305), _ms(16));
      expect(tracker.pointerMove(1, const Offset(440, 500), _ms(32)).type, MobileDismissDragEventType.none);
      expect(tracker.isActive, isFalse);
    });

    testWidgets('a diagonal start is too ambiguous to close a player on', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: true);
      tracker.pointerMove(1, const Offset(425, 325), _ms(16));
      expect(tracker.isActive, isFalse);
    });

    testWidgets('a second finger mid-drag (a pinch) cancels and blocks until every finger lifts', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: true);
      tracker.pointerMove(1, const Offset(400, 360), _ms(16));
      expect(tracker.isActive, isTrue);

      expect(
        tracker.pointerDown(2, const Offset(500, 300), _ms(32), canStart: true).type,
        MobileDismissDragEventType.cancelled,
      );
      expect(tracker.pointerMove(1, const Offset(400, 500), _ms(48)).type, MobileDismissDragEventType.none);
      expect(tracker.pointerUp(1, const Offset(400, 500), _ms(64)).type, MobileDismissDragEventType.none);
      // The remaining finger still cannot start a close.
      expect(tracker.pointerMove(2, const Offset(500, 500), _ms(80)).type, MobileDismissDragEventType.none);
      tracker.pointerUp(2, const Offset(500, 500), _ms(96));

      // All fingers up: the next touch is a fresh gesture.
      final next = _dragDown(tracker, pointer: 3);
      expect(next.last.type, MobileDismissDragEventType.ended);
    });

    testWidgets('cancel() (long-press 2x took over) ends the drag and ignores the rest of the touch', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: true);
      tracker.pointerMove(1, const Offset(400, 360), _ms(16));
      expect(tracker.cancel().type, MobileDismissDragEventType.cancelled);
      expect(tracker.pointerMove(1, const Offset(400, 500), _ms(32)).type, MobileDismissDragEventType.none);
      expect(tracker.pointerUp(1, const Offset(400, 500), _ms(48)).type, MobileDismissDragEventType.none);
    });

    testWidgets('a touch that may not start never engages', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: false);
      expect(tracker.pointerMove(1, const Offset(400, 500), _ms(16)).type, MobileDismissDragEventType.none);
    });

    testWidgets('a pointer cancel mid-drag settles back instead of closing', (tester) async {
      final tracker = MobileDismissDragTracker();
      tracker.pointerDown(1, const Offset(400, 300), _ms(0), canStart: true);
      tracker.pointerMove(1, const Offset(400, 400), _ms(16));
      expect(tracker.pointerCancel(1).type, MobileDismissDragEventType.cancelled);
    });
  });

  group('mobileDismissDragCanStartAt', () {
    const size = Size(800, 600); // 90 px top/bottom bands, 96 px edge zones
    bool allEdges(MobileEdgeAdjustmentSide _) => true;
    bool noEdges(MobileEdgeAdjustmentSide _) => false;

    test('the middle of the frame can start', () {
      expect(
        mobileDismissDragCanStartAt(position: const Offset(400, 300), size: size, isEdgeSideEnabled: allEdges),
        isTrue,
      );
    });

    test('the top and bottom bands cannot — header, timeline, and the system edge gestures', () {
      expect(
        mobileDismissDragCanStartAt(position: const Offset(400, 40), size: size, isEdgeSideEnabled: allEdges),
        isFalse,
      );
      expect(
        mobileDismissDragCanStartAt(position: const Offset(400, 570), size: size, isEdgeSideEnabled: allEdges),
        isFalse,
      );
    });

    test('an edge belongs to brightness/volume only while that swipe is enabled', () {
      expect(
        mobileDismissDragCanStartAt(position: const Offset(40, 300), size: size, isEdgeSideEnabled: allEdges),
        isFalse,
      );
      expect(
        mobileDismissDragCanStartAt(position: const Offset(760, 300), size: size, isEdgeSideEnabled: allEdges),
        isFalse,
      );
      expect(
        mobileDismissDragCanStartAt(position: const Offset(40, 300), size: size, isEdgeSideEnabled: noEdges),
        isTrue,
      );
    });
  });

  group('dismissDragShouldClose', () {
    test('past a quarter of the height closes at any speed', () {
      expect(dismissDragShouldClose(offset: 151, velocity: 0, viewportHeight: 600), isTrue);
      expect(dismissDragShouldClose(offset: 149, velocity: 0, viewportHeight: 600), isFalse);
    });

    test('a flick closes short of that, but not a twitch', () {
      expect(dismissDragShouldClose(offset: 60, velocity: 900, viewportHeight: 600), isTrue);
      expect(dismissDragShouldClose(offset: 30, velocity: 900, viewportHeight: 600), isFalse);
      expect(dismissDragShouldClose(offset: 60, velocity: 400, viewportHeight: 600), isFalse);
    });

    test('an upward flick at the end cancels', () {
      expect(dismissDragShouldClose(offset: 100, velocity: -900, viewportHeight: 600), isFalse);
    });
  });
}
