import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import '../pipelines/pipeline1/safety_coordinator.dart';
import '../pipelines/pipeline1/yolo_ncnn_runner.dart';
import '../pipelines/pipeline2/conversation_coordinator.dart';
import '../pipelines/pipeline2/frame_selector.dart';
import '../pipelines/pipeline2/silero_vad.dart';
import '../pipelines/pipeline2/vlm_runner.dart';
import '../widgets/camera_overlay.dart';
import '../widgets/pipeline_status_badge.dart';
import '../widgets/response_bubble.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  final FrameSelector _frameSelector = FrameSelector();
  bool _cameraReady = false;
  bool _permissionsGranted = false;

  // Conversation state
  String _transcript = '';
  String _response = '';
  List<String> _responseSentences = [];

  StreamSubscription? _p2StateSub;
  StreamSubscription? _transcriptSub;
  StreamSubscription? _responseSub;
  StreamSubscription? _detectionSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
  }

  Future<void> _initApp() async {
    await _requestPermissions();
    if (!_permissionsGranted) return;
    await _initCamera();
    await _initPipelines();
  }

  Future<void> _requestPermissions() async {
    final statuses = await [Permission.camera, Permission.microphone].request();
    final granted = statuses.values.every((s) => s == PermissionStatus.granted);
    setState(() => _permissionsGranted = granted);
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera and microphone permissions are required.')),
      );
    }
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) return;
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _cameraController = CameraController(
      back,
      ResolutionPreset.medium, // 720p — balance quality vs inference speed
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await _cameraController!.initialize();
      setState(() => _cameraReady = true);

      // Start image stream for dual pipeline
      await _cameraController!.startImageStream((image) async {
        _frameSelector.addFrame(image);
        await SafetyCoordinator.instance.processFrame(image);
      });
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _initPipelines() async {
    // Pipeline 1
    await SafetyCoordinator.instance.start();

    // Pipeline 2
    await SileroVad.instance.init();
    await VlmRunner.instance.init();
    await VlmRunner.instance.loadModel();
    ConversationCoordinator.instance.attachFrameSelector(_frameSelector);
    await ConversationCoordinator.instance.start();

    // Subscribe to P2 events
    _p2StateSub = ConversationCoordinator.instance.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _transcriptSub = ConversationCoordinator.instance.transcriptStream.listen((t) {
      if (mounted) setState(() { _transcript = t; });
    });
    _responseSub = ConversationCoordinator.instance.responseStream.listen((s) {
      if (mounted) setState(() {
        _responseSentences.add(s);
        _response = _responseSentences.join(' ');
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      SafetyCoordinator.instance.pause();
    } else if (state == AppLifecycleState.resumed) {
      SafetyCoordinator.instance.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _p2StateSub?.cancel();
    _transcriptSub?.cancel();
    _responseSub?.cancel();
    _detectionSub?.cancel();
    SafetyCoordinator.instance.stop();
    ConversationCoordinator.instance.stop();
    super.dispose();
  }

  void _clearConversation() {
    setState(() { _transcript = ''; _response = ''; _responseSentences.clear(); });
  }

  @override
  Widget build(BuildContext context) {
    final p2State = ConversationCoordinator.instance.state;
    final p1State = SafetyCoordinator.instance.state;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Full-bleed camera preview ─────────────────────────────────────
          if (_cameraReady && _cameraController != null)
            Positioned.fill(
              child: CameraPreview(_cameraController!),
            )
          else
            Positioned.fill(
              child: Container(
                color: const Color(0xFF0A0A14),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(color: Color(0xFF6C63FF)),
                    const Gap(16),
                    Text(!_permissionsGranted
                        ? 'Camera permission required'
                        : 'Initialising camera...',
                      style: const TextStyle(color: Colors.white54)),
                  ]),
                ),
              ),
            ),

          // ── Detection overlay bounding boxes ─────────────────────────────
          if (_cameraReady)
            StreamBuilder(
              stream: SafetyCoordinator.instance.detectionsStream,
              builder: (ctx, snap) => CameraOverlay(
                detections: snap.data ?? [],
                imageSize: _cameraController != null
                    ? Size(_cameraController!.value.previewSize!.height,
                        _cameraController!.value.previewSize!.width)
                    : Size.zero,
              ),
            ),

          // ── Top bar: settings + FPS ───────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  // App logo
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(children: [
                      const Icon(Icons.visibility, color: Color(0xFF6C63FF), size: 18),
                      const Gap(6),
                      const Text('Narrator', style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                    ]),
                  ),
                  const Spacer(),
                  // FPS badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${SafetyCoordinator.instance.currentFps.toStringAsFixed(0)} FPS',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  const Gap(8),
                  // Settings
                  GestureDetector(
                    onTap: () => Navigator.pushNamed(context, '/settings'),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.settings_outlined, color: Colors.white, size: 20),
                    ),
                  ),
                ]),
              ),
            ),
          ),

          // ── Pipeline status badges ────────────────────────────────────────
          Positioned(
            top: 80, left: 16, right: 16,
            child: Row(children: [
              PipelineStatusBadge(
                label: 'P1',
                sublabel: 'Safety',
                isActive: p1State == Pipeline1State.running,
                color: const Color(0xFFFF6B6B),
              ),
              const Gap(10),
              PipelineStatusBadge(
                label: 'P2',
                sublabel: _p2StateLabel(p2State),
                isActive: p2State != Pipeline2State.idle,
                color: const Color(0xFF6C63FF),
                isPulsing: p2State == Pipeline2State.recording,
              ),
            ]),
          ).animate().fadeIn(delay: 600.ms),

          // ── Bottom panel: transcript + response ───────────────────────────
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withOpacity(0.95), Colors.transparent],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Transcript bubble
                  if (_transcript.isNotEmpty)
                    ResponseBubble(
                      text: _transcript,
                      isUser: true,
                      key: const ValueKey('transcript'),
                    ).animate().fadeIn().slideY(begin: 0.3, end: 0),

                  if (_response.isNotEmpty) ...[
                    const Gap(8),
                    ResponseBubble(
                      text: _response,
                      isUser: false,
                      key: ValueKey(_response.length),
                    ).animate().fadeIn().slideY(begin: 0.3, end: 0),
                  ],

                  const Gap(16),

                  // Push-to-Talk button
                  Row(children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          _clearConversation();
                          ConversationCoordinator.instance.triggerManually();
                        },
                        child: Container(
                          height: 60,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: p2State == Pipeline2State.recording
                                  ? [const Color(0xFFFF6B6B), const Color(0xFFFF8E53)]
                                  : [const Color(0xFF6C63FF), const Color(0xFF9C59FF)],
                            ),
                            borderRadius: BorderRadius.circular(30),
                            boxShadow: [
                              BoxShadow(
                                color: (p2State == Pipeline2State.recording
                                    ? const Color(0xFFFF6B6B)
                                    : const Color(0xFF6C63FF)).withOpacity(0.4),
                                blurRadius: 20, spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(
                              p2State == Pipeline2State.recording
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded,
                              color: Colors.white, size: 26,
                            ),
                            const Gap(10),
                            Text(
                              p2State == Pipeline2State.recording ? 'Listening...'
                                  : p2State == Pipeline2State.thinking ? 'Thinking...'
                                  : p2State == Pipeline2State.speaking ? 'Speaking...'
                                  : 'Ask a Question',
                              style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ]),
                        ),
                      ),
                    ),
                    if (_response.isNotEmpty) ...[
                      const Gap(12),
                      GestureDetector(
                        onTap: _clearConversation,
                        child: Container(
                          width: 50, height: 50,
                          decoration: BoxDecoration(
                            color: Colors.white10, shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24)),
                          child: const Icon(Icons.close, color: Colors.white54, size: 20),
                        ),
                      ),
                    ],
                  ]),

                  // Wake word hint
                  if (p2State == Pipeline2State.awaitingWakeWord)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Center(
                        child: Text('Say "Suno" or "Hey Narrator" to start',
                          style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12)),
                      ),
                    ).animate(onPlay: (c) => c.repeat())
                        .shimmer(duration: 2.seconds, color: Colors.white24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _p2StateLabel(Pipeline2State s) {
    switch (s) {
      case Pipeline2State.idle: return 'Idle';
      case Pipeline2State.awaitingWakeWord: return 'Listening';
      case Pipeline2State.recording: return 'Recording';
      case Pipeline2State.transcribing: return 'STT';
      case Pipeline2State.thinking: return 'Thinking';
      case Pipeline2State.speaking: return 'Speaking';
      case Pipeline2State.error: return 'Error';
    }
  }
}
