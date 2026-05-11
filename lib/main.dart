import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import 'colorizer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Colorify',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const ColorifyScreen(),
    );
  }
}

class ColorifyScreen extends StatefulWidget {
  const ColorifyScreen({super.key});

  @override
  State<ColorifyScreen> createState() => _ColorifyScreenState();
}

class _ColorifyScreenState extends State<ColorifyScreen>
    with SingleTickerProviderStateMixin {
  final _colorizer = DDColorizer();
  final _picker = ImagePicker();

  img.Image? _source;

  Uint8List? _grayBytes;
  Uint8List? _coloredBytes;

  bool _modelLoading = false;
  bool _inferring = false;
  bool _saving = false;

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    _preloadModel();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _colorizer.dispose();
    super.dispose();
  }

  Future<void> _preloadModel() async {
    setState(() => _modelLoading = true);
    await _colorizer.init();
    if (mounted) setState(() => _modelLoading = false);
  }

  Future<void> _pickImage() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;

    // Build grayscale preview at display resolution (same cap as colorize output
    // so both cards show images at identical dimensions).
    const maxDisplay = 1024;
    final scale =
        min(maxDisplay / max(decoded.width, decoded.height), 1.0);
    final dispW = max((decoded.width * scale).round(), 1);
    final dispH = max((decoded.height * scale).round(), 1);

    final grayImg = img.grayscale(img.copyResize(decoded,
        width: dispW,
        height: dispH,
        interpolation: img.Interpolation.linear));
    final grayBytes =
        Uint8List.fromList(img.encodeJpg(grayImg, quality: 88));

    setState(() {
      _source = decoded;
      _grayBytes = grayBytes;
      _coloredBytes = null;
    });
    _fadeCtrl.reset();
  }

  Future<void> _saveToGallery() async {
    if (_coloredBytes == null || _saving) return;
    setState(() => _saving = true);
    try {
      await Gal.putImageBytes(
        _coloredBytes!,
        name: 'colorify_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 18),
                SizedBox(width: 10),
                Text('Saved to gallery'),
              ],
            ),
            backgroundColor: const Color(0xFF7C4DFF),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _colorize() async {
    if (_source == null || _inferring) return;
    setState(() => _inferring = true);

    try {
      final colored = await _colorizer.colorize(_source!);
      final bytes =
          Uint8List.fromList(img.encodeJpg(colored, quality: 92));
      if (mounted) {
        setState(() {
          _coloredBytes = bytes;
          _inferring = false;
        });
        _fadeCtrl.forward(from: 0);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _inferring = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Colorization failed: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          _buildBody(),
          if (_modelLoading || _inferring) _buildLoadingOverlay(),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF7C4DFF), Color(0xFFFF4081)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
        ),
        child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.palette, color: Colors.white, size: 22),
              SizedBox(width: 8),
              Text(
                'Colorify',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          actions: [
            if (_coloredBytes != null)
              _saving
                  ? const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        ),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.save_alt, color: Colors.white),
                      tooltip: 'Save to Gallery',
                      onPressed: _saveToGallery,
                    ),
            if (_modelLoading)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_grayBytes == null) return _buildEmptyState();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ImageCard(
            label: 'Original (B&W)',
            labelColor: const Color(0xFF4A4A6A),
            bytes: _grayBytes!,
          ),
          if (_coloredBytes != null) ...[
            const SizedBox(height: 16),
            FadeTransition(
              opacity: _fadeAnim,
              child: _ImageCard(
                label: 'Colorized  ✦ AI',
                labelColor: const Color(0xFF7C4DFF),
                bytes: _coloredBytes!,
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            _buildHint(),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF7C4DFF).withValues(alpha: 0.3),
                    Colors.transparent,
                  ],
                ),
              ),
              child: const Icon(
                Icons.photo_camera_back_outlined,
                size: 64,
                color: Color(0xFF7C4DFF),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Upload a B&W Photo',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'The AI will breathe color into your\nblack & white images.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 32),
            _modelLoading
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF7C4DFF),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Loading AI model (215 MB)…',
                        style:
                            TextStyle(color: Colors.grey.shade500, fontSize: 13),
                      ),
                    ],
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C4DFF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Model ready',
                      style: TextStyle(
                          color: Color(0xFF7C4DFF), fontSize: 13),
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildHint() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.arrow_downward,
            size: 14, color: Colors.grey.shade600),
        const SizedBox(width: 6),
        Text(
          'Tap "Colorize" to run the AI',
          style:
              TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildLoadingOverlay() {
    final msg = _modelLoading ? 'Loading model…' : 'Colorizing with AI…';
    return Container(
      color: Colors.black.withValues(alpha: 0.65),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: Color(0xFF7C4DFF),
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              msg,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (_inferring) ...[
              const SizedBox(height: 6),
              Text(
                'DDColor · 256 × 256 · On-device',
                style:
                    TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final canColorize =
        _source != null && !_inferring && !_modelLoading;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_inferring || _modelLoading) ? null : _pickImage,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Pick Image'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(color: Colors.grey.shade700),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: canColorize
                      ? const LinearGradient(
                          colors: [Color(0xFF7C4DFF), Color(0xFFFF4081)],
                        )
                      : null,
                  color: canColorize ? null : Colors.grey.shade800,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: FilledButton.icon(
                  onPressed: canColorize ? _colorize : null,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Colorize'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    disabledBackgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageCard extends StatelessWidget {
  const _ImageCard({
    required this.label,
    required this.labelColor,
    required this.bytes,
  });

  final String label;
  final Color labelColor;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          border: Border.all(color: labelColor.withValues(alpha: 0.35), width: 1.2),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: labelColor.withValues(alpha: 0.18),
              child: Text(
                label,
                style: TextStyle(
                  color: labelColor == const Color(0xFF4A4A6A)
                      ? Colors.grey.shade400
                      : Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            Image.memory(bytes, fit: BoxFit.contain),
          ],
        ),
      ),
    );
  }
}
