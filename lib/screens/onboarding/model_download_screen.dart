import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:percent_indicator/percent_indicator.dart';
import '../../core/model_manager.dart';

class ModelDownloadScreen extends StatefulWidget {
  const ModelDownloadScreen({super.key});
  @override
  State<ModelDownloadScreen> createState() => _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends State<ModelDownloadScreen> {
  bool _downloading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ModelManager.instance.onProgress = (file, progress) {
      if (mounted) setState(() {});
    };
    ModelManager.instance.onStatusChanged = (file, status) {
      if (mounted) setState(() {});
    };
  }

  Future<void> _startDownload() async {
    setState(() { _downloading = true; _error = null; });
    try {
      await ModelManager.instance.downloadAll();
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home');
    } catch (e) {
      setState(() { _error = e.toString(); _downloading = false; });
    }
  }

  void _skipToHome() => Navigator.pushReplacementNamed(context, '/home');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final models = ModelManager.instance.models;
    final totalMb = ModelManager.instance.totalRequiredMb;
    final downloadedMb = ModelManager.instance.totalDownloadedMb;
    final allReady = ModelManager.instance.pipeline2Ready;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(16),
              Text('Download AI Models',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold, color: Colors.white),
              ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.2, end: 0),
              const Gap(6),
              Text('These models run entirely on your device — no internet needed after download.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white54),
              ).animate().fadeIn(delay: 200.ms),
              const Gap(24),

              // Total progress summary
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [cs.primary.withOpacity(0.15), cs.secondary.withOpacity(0.08)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.primary.withOpacity(0.3)),
                ),
                child: Row(children: [
                  CircularPercentIndicator(
                    radius: 36,
                    lineWidth: 5,
                    percent: totalMb > 0 ? (downloadedMb / totalMb).clamp(0.0, 1.0) : 0,
                    center: Text('${((downloadedMb / totalMb.clamp(1, totalMb)) * 100).toInt()}%',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    progressColor: cs.primary,
                    backgroundColor: Colors.white12,
                    circularStrokeCap: CircularStrokeCap.round,
                  ),
                  const Gap(16),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('$downloadedMb MB / $totalMb MB downloaded',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    const Gap(4),
                    Text(allReady ? '✓ All models ready' : '${models.where((m) => m.status == ModelStatus.ready).length}/${models.length} models ready',
                      style: TextStyle(color: allReady ? const Color(0xFF00D4AA) : Colors.white54, fontSize: 13)),
                  ])),
                ]),
              ).animate().fadeIn(delay: 300.ms),
              const Gap(20),

              // Model list
              Expanded(
                child: ListView.separated(
                  itemCount: models.length,
                  separatorBuilder: (_, __) => const Gap(10),
                  itemBuilder: (ctx, i) => _ModelTile(model: models[i]),
                ),
              ),

              if (_error != null) ...[
                const Gap(12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B6B).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('Error: $_error',
                    style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12)),
                ),
              ],

              const Gap(16),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: _downloading ? null : _startDownload,
                      icon: _downloading
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.download_rounded, color: Colors.white),
                      label: Text(_downloading ? 'Downloading...' : 'Download All',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: cs.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ),
                const Gap(12),
                SizedBox(
                  height: 54,
                  child: OutlinedButton(
                    onPressed: _downloading ? null : _skipToHome,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('Later', style: TextStyle(color: Colors.white54)),
                  ),
                ),
              ]).animate().fadeIn(delay: 500.ms),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final ModelInfo model;
  const _ModelTile({required this.model});

  bool get _isManual => model.url.isEmpty;

  @override
  Widget build(BuildContext context) {
    final isReady = model.status == ModelStatus.ready;
    final isDownloading = model.status == ModelStatus.downloading;
    final autoColor = isReady ? const Color(0xFF00D4AA) : const Color(0xFF6C63FF);
    final manualColor = const Color(0xFFFFAA00);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isReady
              ? const Color(0xFF00D4AA).withOpacity(0.3)
              : _isManual
                  ? manualColor.withOpacity(0.2)
                  : Colors.white10,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            isReady
                ? Icons.check_circle_rounded
                : _isManual
                    ? Icons.build_outlined
                    : Icons.cloud_download_outlined,
            color: isReady
                ? const Color(0xFF00D4AA)
                : _isManual
                    ? manualColor
                    : Colors.white38,
            size: 20,
          ),
          const Gap(10),
          Expanded(
            child: Text(model.name,
              style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          // Badge: Manual or size
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: _isManual
                  ? manualColor.withOpacity(0.15)
                  : Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _isManual ? 'Manual' : '~${model.estimatedSizeMb}MB',
              style: TextStyle(
                color: _isManual ? manualColor : Colors.white38,
                fontSize: 11,
                fontWeight: _isManual ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ]),
        const Gap(4),
        Text(model.description,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),

        // Manual download instruction
        if (_isManual && !isReady) ...[
          const Gap(8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: manualColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: manualColor.withOpacity(0.2)),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, color: manualColor, size: 14),
              const Gap(8),
              Expanded(
                child: Text(
                  'Download manually — see README for link & ADB push command.',
                  style: TextStyle(color: manualColor, fontSize: 11, height: 1.4),
                ),
              ),
            ]),
          ),
        ],

        // Progress bar for downloading
        if (isDownloading) ...[
          const Gap(8),
          LinearProgressIndicator(
            value: model.progress,
            backgroundColor: Colors.white10,
            color: autoColor,
            borderRadius: BorderRadius.circular(4),
          ),
          const Gap(4),
          Text('${(model.progress * 100).toInt()}%',
            style: TextStyle(color: autoColor, fontSize: 11)),
        ],
      ]),
    );
  }
}
