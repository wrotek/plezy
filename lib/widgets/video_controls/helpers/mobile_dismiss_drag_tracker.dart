import 'dart:math' as math;
import 'dart:ui' show Offset, Size, VoidCallback;

import 'package:flutter/gestures.dart' show PointerDeviceKind, VelocityTracker, kTouchSlop;

import '../widgets/mobile_skip_zones.dart';
import 'mobile_edge_adjustment_tracker.dart';

/// Where a finger swipe-down-to-close may start.
///
/// The middle of the frame only: the left/right edges belong to the
/// brightness/volume swipes (when enabled), and the top/bottom bands — the same
/// exclusions the skip zones use — hold the header and the timeline, and on
/// iPadOS border the system's own Notification Center and Home gestures.
bool mobileDismissDragCanStartAt({
  required Offset position,
  required Size size,
  required bool Function(MobileEdgeAdjustmentSide side) isEdgeSideEnabled,
}) {
  final dimensions = mobileSkipZoneDimensions(size);
  if (position.dy <= dimensions.topExclude || position.dy >= size.height - dimensions.bottomExclude) return false;
  final edge = mobileEdgeAdjustmentZoneForPosition(position: position, size: size);
  return edge == null || !isEdgeSideEnabled(edge);
}

/// Whether releasing a dismiss drag closes the player — shared by the trackpad
/// and finger paths.
///
/// The overlay sheet system's thresholds (a quarter of the height, or a flick
/// over 500 px/s), plus a minimum travel on the flick so a twitch of the finger
/// cannot close the player.
bool dismissDragShouldClose({required double offset, required double velocity, required double viewportHeight}) {
  if (offset <= 0) return false;
  if (offset > viewportHeight * 0.25) return true;
  return velocity > 500 && offset > 48;
}

/// The player screen's side of the swipe: it owns the offset the picture
/// follows and decides whether a release closes.
class MobileDismissDragHandlers {
  const MobileDismissDragHandlers({required this.onUpdate, required this.onEnd, required this.onCancel});

  /// Downward offset from where the drag engaged, in logical pixels, never negative.
  final void Function(double offset) onUpdate;

  /// Release, with the vertical velocity in logical pixels per second (down is positive).
  final void Function(double velocity) onEnd;

  /// The drag was abandoned — settle back without closing.
  final VoidCallback onCancel;
}

enum MobileDismissDragEventType { none, update, ended, cancelled }

class MobileDismissDragEvent {
  const MobileDismissDragEvent._(this.type, {this.offset = 0.0, this.velocity = 0.0});

  const MobileDismissDragEvent.none() : this._(MobileDismissDragEventType.none);
  const MobileDismissDragEvent.update(double offset) : this._(MobileDismissDragEventType.update, offset: offset);
  const MobileDismissDragEvent.ended(double velocity) : this._(MobileDismissDragEventType.ended, velocity: velocity);
  const MobileDismissDragEvent.cancelled() : this._(MobileDismissDragEventType.cancelled);

  final MobileDismissDragEventType type;
  final double offset;
  final double velocity;
}

/// Single-finger swipe-down-to-close, tracked from raw pointers.
///
/// Deliberately outside the gesture arena, like [MobileEdgeAdjustmentTracker]:
/// the content strip's vertical drag sits deeper in the tree and would win any
/// arena contest, and a downward drag is a no-op for it anyway (the strip only
/// opens upwards). Everything else is excluded by construction —
/// a second finger (pinch, two-finger tap) blocks until all fingers lift, a
/// horizontal or upward start (scrub, content strip) rejects the pointer, and
/// the caller cancels on long-press 2x.
class MobileDismissDragTracker {
  MobileDismissDragTracker({this.slop = kTouchSlop, this.verticalDominance = 1.5});

  final double slop;
  final double verticalDominance;

  final Set<int> _activePointers = <int>{};
  int? _trackedPointer;
  Offset? _startPosition;
  double? _engagedAtY;
  VelocityTracker? _velocityTracker;
  bool _blockedUntilAllPointersUp = false;

  bool get isActive => _engagedAtY != null;

  MobileDismissDragEvent pointerDown(int pointer, Offset position, Duration timeStamp, {required bool canStart}) {
    _activePointers.add(pointer);
    if (_blockedUntilAllPointersUp) return const MobileDismissDragEvent.none();
    if (_activePointers.length > 1) return _cancelTracking(blockUntilAllPointersUp: true);
    if (_trackedPointer != null || !canStart) return const MobileDismissDragEvent.none();

    _trackedPointer = pointer;
    _startPosition = position;
    _engagedAtY = null;
    _velocityTracker = VelocityTracker.withKind(PointerDeviceKind.touch)..addPosition(timeStamp, position);
    return const MobileDismissDragEvent.none();
  }

  MobileDismissDragEvent pointerMove(int pointer, Offset position, Duration timeStamp) {
    if (pointer != _trackedPointer) return const MobileDismissDragEvent.none();
    final start = _startPosition;
    if (start == null) return const MobileDismissDragEvent.none();
    _velocityTracker?.addPosition(timeStamp, position);

    final engagedAtY = _engagedAtY;
    if (engagedAtY != null) return MobileDismissDragEvent.update(math.max(0.0, position.dy - engagedAtY));

    final delta = position - start;
    final absDx = delta.dx.abs();
    final absDy = delta.dy.abs();
    if (absDx >= slop && absDx > absDy * verticalDominance) return _cancelTracking(blockUntilAllPointersUp: true);
    if (absDy < slop) return const MobileDismissDragEvent.none();
    // Upward is the content strip; diagonal is too ambiguous to close a player on.
    if (delta.dy < 0 || absDy <= absDx * verticalDominance) return _cancelTracking(blockUntilAllPointersUp: true);

    // Measured from here rather than the touch-down point, so the picture
    // starts following the finger without first jumping by the slop.
    _engagedAtY = position.dy;
    return const MobileDismissDragEvent.update(0.0);
  }

  MobileDismissDragEvent pointerUp(int pointer, Offset position, Duration timeStamp) {
    _activePointers.remove(pointer);
    if (_activePointers.isEmpty) _blockedUntilAllPointersUp = false;
    if (pointer != _trackedPointer) return const MobileDismissDragEvent.none();

    final wasActive = isActive;
    _velocityTracker?.addPosition(timeStamp, position);
    final velocity = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0.0;
    _resetTracking();
    return wasActive ? MobileDismissDragEvent.ended(velocity) : const MobileDismissDragEvent.none();
  }

  MobileDismissDragEvent pointerCancel(int pointer) {
    _activePointers.remove(pointer);
    if (_activePointers.isEmpty) _blockedUntilAllPointersUp = false;
    if (pointer != _trackedPointer) return const MobileDismissDragEvent.none();
    return _cancelTracking(blockUntilAllPointersUp: _activePointers.isNotEmpty);
  }

  /// Abandon the current drag (long-press 2x took over, gestures got disallowed).
  /// Later moves of the same finger are ignored until it lifts.
  MobileDismissDragEvent cancel() => _cancelTracking(blockUntilAllPointersUp: _activePointers.isNotEmpty);

  MobileDismissDragEvent _cancelTracking({required bool blockUntilAllPointersUp}) {
    final wasActive = isActive;
    _resetTracking();
    if (blockUntilAllPointersUp && _activePointers.isNotEmpty) _blockedUntilAllPointersUp = true;
    return wasActive ? const MobileDismissDragEvent.cancelled() : const MobileDismissDragEvent.none();
  }

  void _resetTracking() {
    _trackedPointer = null;
    _startPosition = null;
    _engagedAtY = null;
    _velocityTracker = null;
  }
}
