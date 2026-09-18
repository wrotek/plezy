import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/helpers/mobile_dismiss_drag_tracker.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// Finger swipe-down-to-close, driven through the real controls.
///
/// The swipe is tracked from raw pointers because in the gesture arena it would
/// lose to the content strip's vertical drag. So the cases that matter are the
/// ones where that detector is actually mounted — chrome up, item with
/// chapters — and the neighbours it must not steal from: the strip itself,
/// the edge swipes, pinch, and long-press 2x.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late List<double> updates;
  late List<double> ends;
  late int cancels;
  var pointer = 900;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();

    TvDetectionService.debugSetAppleTVOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(false);

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _RecordingPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: SettingsService.instance, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    updates = [];
    ends = [];
    cancels = 0;
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await database.close();
  });

  const surface = Size(800, 600);

  Future<void> pumpControls(WidgetTester tester, {bool chromeVisible = false, bool withChapters = false}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS, extensions: const [testMonoTokens]),
          home: Scaffold(
            body: SizedBox(
              width: surface.width,
              height: surface.height,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: testMediaItem(id: 'dismiss-drag'),
                toastController: toast,
                chromeController: chrome,
                canNavigateMediaItems: false,
                initialChapters: withChapters
                    ? [
                        MediaChapter(id: 1, index: 0, startTimeOffset: 0, endTimeOffset: 600000, title: 'One'),
                        MediaChapter(id: 2, index: 1, startTimeOffset: 600000, endTimeOffset: 2700000, title: 'Two'),
                      ]
                    : null,
                dismissDrag: MobileDismissDragHandlers(
                  onUpdate: updates.add,
                  onEnd: ends.add,
                  onCancel: () => cancels++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    if (chromeVisible) {
      chrome.show();
      await tester.pump(const Duration(milliseconds: 300));
      expect(chrome.controlsVisible, isTrue);
    } else {
      chrome.hide();
      chrome.markControlsHidden();
      await tester.pump();
      expect(chrome.controlsVisible, isFalse);
    }
  }

  Offset origin(WidgetTester tester, Offset local) => tester.getTopLeft(find.byType(PlexVideoControls)) + local;

  /// One finger, 20 px steps 16 ms apart — 1250 px/s, a real swipe.
  Future<void> swipe(WidgetTester tester, {required Offset from, required Offset step, int steps = 10}) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: pointer++);
    await gesture.down(origin(tester, from));
    for (var i = 1; i <= steps; i++) {
      await gesture.moveBy(step, timeStamp: Duration(milliseconds: 16 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up(timeStamp: Duration(milliseconds: 16 * steps));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    chrome.cancelAutoHide();
    toast.hide();
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('a finger swipe down reaches the screen, chrome hidden', (tester) async {
    await pumpControls(tester);

    await swipe(tester, from: const Offset(400, 200), step: const Offset(0, 20));

    expect(updates, isNotEmpty);
    expect(updates.last, closeTo(180, 1));
    expect(ends, hasLength(1));
    expect(ends.single, greaterThan(500));
    expect(cancels, 0);

    await settle(tester);
  });

  testWidgets('it still wins with the chrome up and the content strip mounted — the trackpad regression', (
    tester,
  ) async {
    await pumpControls(tester, chromeVisible: true, withChapters: true);

    await swipe(tester, from: const Offset(400, 200), step: const Offset(0, 20));

    expect(ends, hasLength(1), reason: 'the strip detector must not swallow the finger');
    expect(chrome.contentStripVisible, isFalse, reason: 'and a downward swipe must not open the strip');

    await settle(tester);
  });

  testWidgets('swiping up still opens the content strip and never reaches the screen', (tester) async {
    await pumpControls(tester, chromeVisible: true, withChapters: true);

    await swipe(tester, from: const Offset(400, 400), step: const Offset(0, -20));
    await tester.pumpAndSettle();

    expect(updates, isEmpty);
    expect(ends, isEmpty);
    expect(chrome.contentStripVisible, isTrue);

    await settle(tester);
  });

  testWidgets('an edge swipe is brightness/volume, not a close', (tester) async {
    await pumpControls(tester);

    await swipe(tester, from: const Offset(40, 200), step: const Offset(0, 20));
    await swipe(tester, from: const Offset(760, 200), step: const Offset(0, 20));

    expect(updates, isEmpty);
    expect(ends, isEmpty);

    // The swipes really did adjust brightness/volume: let the indicator's
    // hide timer run out before tearing down.
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
  });

  testWidgets('with the brightness swipe turned off, its edge is free to close from', (tester) async {
    await SettingsService.instance.write(SettingsService.gestureBrightnessSwipe, false);
    await pumpControls(tester);

    await swipe(tester, from: const Offset(40, 200), step: const Offset(0, 20));

    expect(ends, hasLength(1));

    await settle(tester);
  });

  testWidgets('a swipe from the top band is left to the system', (tester) async {
    await pumpControls(tester);

    await swipe(tester, from: const Offset(400, 40), step: const Offset(0, 20));

    expect(updates, isEmpty);

    await settle(tester);
  });

  testWidgets('a second finger landing mid-swipe (pinch) settles back instead of closing', (tester) async {
    await pumpControls(tester);

    final first = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: pointer++);
    await first.down(origin(tester, const Offset(400, 200)));
    for (var i = 1; i <= 5; i++) {
      await first.moveBy(const Offset(0, 20), timeStamp: Duration(milliseconds: 16 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(updates, isNotEmpty);

    final second = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: pointer++);
    await second.down(origin(tester, const Offset(500, 300)));
    await first.moveBy(const Offset(0, 100), timeStamp: const Duration(milliseconds: 120));
    await first.up(timeStamp: const Duration(milliseconds: 140));
    await second.up(timeStamp: const Duration(milliseconds: 140));
    await tester.pump();

    expect(cancels, 1);
    expect(ends, isEmpty);

    await settle(tester);
  });

  testWidgets('holding for 2x and then sliding down does not close', (tester) async {
    await pumpControls(tester);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: pointer++);
    await gesture.down(origin(tester, const Offset(400, 200)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(player.rates, contains(2.0), reason: 'long-press 2x engaged');

    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(const Offset(0, 20), timeStamp: Duration(milliseconds: 700 + 16 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 900));
    await tester.pump();

    expect(updates, isEmpty);
    expect(ends, isEmpty);

    await settle(tester);
  });

  testWidgets('a mouse drag is not the touch path — the screen handles it in the arena', (tester) async {
    await pumpControls(tester);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: pointer++);
    await gesture.down(origin(tester, const Offset(400, 200)));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(const Offset(0, 20), timeStamp: Duration(milliseconds: 16 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();

    expect(updates, isEmpty);

    await settle(tester);
  });
}

class _RecordingPlayer implements Player {
  bool _playing = true;
  final List<double> rates = [];

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(
    playing: _playing,
    position: const Duration(minutes: 10),
    duration: const Duration(minutes: 45),
    seekable: true,
  );

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: const Stream<Duration>.empty(),
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> playOrPause() async => _playing = !_playing;

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
