import 'dart:math';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class DDColorizer {
  // Model native resolution — cannot be changed.
  static const int _modelSize = 256;

  // Maximum output dimension.  The ab channels are upsampled via bilinear
  // interpolation; capped here so post-processing stays fast on-device.
  static const int _maxOutput = 1024;

  Interpreter? _interpreter;

  Future<void> init() async {
    _interpreter = await Interpreter.fromAsset('assets/models/ddcolor.tflite');
  }

  bool get isReady => _interpreter != null;

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }

  // Returns a grayscale preview resized to [_modelSize] for the "before" card.
  img.Image toGrayscale(img.Image source) {
    return img.grayscale(
      img.copyResize(source,
          width: _modelSize,
          height: _modelSize,
          interpolation: img.Interpolation.linear),
    );
  }

  // Colorizes [source] and returns a full-resolution color image.
  Future<img.Image> colorize(img.Image source) async {
    if (_interpreter == null) await init();

    final origW = source.width;
    final origH = source.height;
    final scaleFactor =
        min(_maxOutput / max(origW, origH), 1.0); // never upscale original
    final outW = max((origW * scaleFactor).round(), 1);
    final outH = max((origH * scaleFactor).round(), 1);

    // Resize to model size, convert to grayscale, feed as [gray,gray,gray]/255.
    final modelInput =
        img.grayscale(img.copyResize(source, width: _modelSize, height: _modelSize));

    final imageMatrix = List.generate(
      _modelSize,
      (y) => List.generate(_modelSize, (x) {
        final v = modelInput.getPixel(x, y).r / 255.0;
        return [v, v, v];
      }),
    );
    final input = [imageMatrix];

    // Output NCHW [1][2][256][256]: channel 0 = a, channel 1 = b.
    // DDColor applies tanh×128 inside the graph, so values are in ~[-128,128].
    final output = [
      List.generate(
        2,
        (_) => List.generate(_modelSize, (_) => List<double>.filled(_modelSize, 0.0)),
      )
    ];
    _interpreter!.run(input, output);

    final abChannels = output[0] as List;

    // Pack a→R, b→G into a uint8 image (offset +128 → [0,255]).
    // Bilinear resize in uint8 space is fine for the smooth ab channels.
    final abImg = img.Image(width: _modelSize, height: _modelSize);
    for (int y = 0; y < _modelSize; y++) {
      for (int x = 0; x < _modelSize; x++) {
        final aVal = ((abChannels[0] as List)[y][x] as double).clamp(-128.0, 127.0);
        final bVal = ((abChannels[1] as List)[y][x] as double).clamp(-128.0, 127.0);
        abImg.setPixelRgb(x, y,
          (aVal + 128).round(), // a → R channel
          (bVal + 128).round(), // b → G channel
          0,
        );
      }
    }
    final abResized = img.copyResize(abImg,
        width: outW, height: outH, interpolation: img.Interpolation.linear);

    // L channel comes from the output-resolution grayscale (preserves detail).
    final grayFull = img.grayscale(
        img.copyResize(source, width: outW, height: outH,
            interpolation: img.Interpolation.linear));

    final result = img.Image(width: outW, height: outH);
    for (int y = 0; y < outH; y++) {
      for (int x = 0; x < outW; x++) {
        final L = _srgbToLabL(grayFull.getPixel(x, y).r / 255.0);
        final abPx = abResized.getPixel(x, y);
        final a = abPx.r.toDouble() - 128.0;
        final b = abPx.g.toDouble() - 128.0;
        final (r, g, bv) = _labToRgb(L, a, b);
        result.setPixelRgb(x, y, r, g, bv);
      }
    }
    return result;
  }

  // sRGB [0,1] → CIE Lab L* [0,100].
  static double _srgbToLabL(double srgb) {
    final lin = srgb <= 0.04045
        ? srgb / 12.92
        : pow((srgb + 0.055) / 1.055, 2.4).toDouble();
    final fy = lin > 0.008856
        ? pow(lin, 1.0 / 3.0).toDouble()
        : 7.787 * lin + 16.0 / 116.0;
    return 116.0 * fy - 16.0;
  }

  // CIE Lab → gamma-corrected sRGB.
  (int, int, int) _labToRgb(double L, double a, double b) {
    final fy = (L + 16.0) / 116.0;
    final fx = a / 500.0 + fy;
    final fz = fy - b / 200.0;

    final x = 0.95047 * _fInv(fx);
    final y = 1.00000 * _fInv(fy);
    final z = 1.08883 * _fInv(fz);

    final rLin = x * 3.2406 + y * -1.5372 + z * -0.4986;
    final gLin = x * -0.9689 + y * 1.8758 + z * 0.0415;
    final bLin = x * 0.0557 + y * -0.2040 + z * 1.0570;

    return (
      (_srgb(rLin) * 255).round().clamp(0, 255),
      (_srgb(gLin) * 255).round().clamp(0, 255),
      (_srgb(bLin) * 255).round().clamp(0, 255),
    );
  }

  static double _fInv(double t) {
    const d = 6.0 / 29.0;
    return t > d ? t * t * t : 3.0 * d * d * (t - 4.0 / 29.0);
  }

  static double _srgb(double v) {
    if (v <= 0.0031308) return 12.92 * v;
    return 1.055 * pow(v, 1.0 / 2.4) - 0.055;
  }
}
