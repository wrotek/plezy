import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/device_adjustment_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/mobile_edge_adjustment_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// On phones and tablets the volume shortcuts (↑/↓ by default) and trackpad
/// scroll move the OS media volume, like the right-edge swipe. They used to
/// scale mpv's own gain, which has no control on the mobile chrome and was
/// persisted across playbacks, so an iPad keyboard could quietly turn every
/// later video down with nothing on screen to show or undo it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const adjustmentChannel = MethodChannel('com.plezy/device_adjustment');

  late _RecordingPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late SettingsService settings;
  late List<MethodCall> adjustmentCalls;
  late double nativeBrightness;
  late double nativeVolume;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();

    // Phone layout: the touch pointer pipeline and the post-frame device
    // adjustment hook are wired only when isMobile(context) && !isTV().
    TvDetectionService.debugSetAppleTVOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(false);

    adjustmentCalls = <MethodCall>[];
    nativeBrightness = 0.5;
    nativeVolume = 0.5;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(adjustmentChannel, (
      call,
    ) async {
      adjustmentCalls.add(call);
      switch (call.method) {
        case 'getBrightness':
          return nativeBrightness;
        case 'setBrightness':
          nativeBrightness = call.arguments as double;
          return null;
        case 'getMediaVolume':
          return nativeVolume;
        case 'setMediaVolume':
          nativeVolume = call.arguments as double;
          return null;
        default:
          return null;
      }
    });

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _RecordingPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(adjustmentChannel, null);
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

  Iterable<MethodCall> callsTo(String method) => adjustmentCalls.where((c) => c.method == method);

  Future<void> pumpControls(WidgetTester tester) async {
    // Reset the shared brightness queue *inside* this test's fake-async zone:
    // a queue future minted in setUp (real zone) or a previous test's zone
    // schedules its completion on a microtask queue this test never flushes.
    DeviceAdjustmentService.instance.resetForTesting();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
          home: Scaffold(
            body: SizedBox(
              width: surface.width,
              height: surface.height,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: testMediaItem(id: 'media-volume-keys'),
                toastController: toast,
                chromeController: chrome,
                canNavigateMediaItems: false,
                canControl: true,
              ),
            ),
          ),
        ),
      ),
    );
    // Post-frame device-adjustment hook, then the queued channel round trips.
    await tester.pump();
    await tester.pump();
    // Swipes start from hidden chrome — visible controls cover the left edge
    // zone and swallow the pointer before the edge Listener sees it.
    chrome.hide();
    chrome.markControlsHidden();
    await tester.pump();
    expect(chrome.controlsVisible, isFalse);
  }

  Future<void> settle(WidgetTester tester) async {
    chrome.cancelAutoHide();
    toast.hide();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Iterable<double> mediaVolumeWrites() => callsTo('setMediaVolume').map((c) => c.arguments as double);

  testWidgets('arrow keys step the OS media volume, not mpv', (tester) async {
    await pumpControls(tester);
    player.volumeWrites.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(mediaVolumeWrites().last, closeTo(0.6, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(mediaVolumeWrites().last, closeTo(0.4, 0.001));

    expect(player.volumeWrites, isEmpty, reason: 'mpv gain must stay put');
    expect(settings.read(SettingsService.volume), 100.0, reason: 'nothing hidden is persisted');

    await settle(tester);
  });

  testWidgets('a key burst chains off its own target, not a stale OS read', (tester) async {
    await pumpControls(tester);

    // The OS applies a level asynchronously; a read between repeats would
    // still see the old value and drop steps.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(adjustmentChannel, (
      call,
    ) async {
      adjustmentCalls.add(call);
      return call.method == 'getMediaVolume' ? 0.5 : null;
    });

    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    }
    await tester.pump();

    expect(mediaVolumeWrites(), [closeTo(0.6, 0.001), closeTo(0.7, 0.001), closeTo(0.8, 0.001)]);
    expect(callsTo('getMediaVolume').length, lessThanOrEqualTo(3), reason: 'one baseline read per burst');

    await settle(tester);
  });

  testWidgets('a key press shows the volume indicator', (tester) async {
    await pumpControls(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(find.byType(MobileEdgeAdjustmentIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(MobileEdgeAdjustmentIndicator), findsNothing, reason: 'it fades like a swipe does');

    await settle(tester);
  });

  testWidgets('trackpad scroll moves the OS media volume', (tester) async {
    await pumpControls(tester);
    player.volumeWrites.clear();

    final center = tester.getCenter(find.byType(PlexVideoControls));
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.pump();

    expect(mediaVolumeWrites().last, closeTo(0.55, 0.001));
    expect(player.volumeWrites, isEmpty);

    await settle(tester);
  });
}

/// Minimal [Player] with a fixed playing state against a 45-minute item.
class _RecordingPlayer implements Player {
  final List<double> volumeWrites = [];

  @override
  Future<void> setVolume(double volume) async => volumeWrites.add(volume);

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(
    playing: true,
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
