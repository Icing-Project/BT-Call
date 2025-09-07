import 'dart:math';
import 'dart:typed_data';

/// Service for 4-FSK modulation and demodulation.
class FourFskService {
  /// Sample rate of the audio or RF front end (e.g., 8000 Hz).
  final int sampleRate;

  /// Symbol rate in symbols per second.
  final double symbolRate;

  /// Four carrier frequencies for symbol mapping.
  final List<double> frequencies;

  FourFskService({
    required this.sampleRate,
    required this.symbolRate,
    required this.frequencies,
  }) {
    if (frequencies.length != 4) {
      throw ArgumentError('Exactly four frequencies required for 4-FSK');
    }
  }

  /// Modulate raw data bytes into a 4-FSK waveform (PCM bytes).
  ///
  /// Each symbol maps 2 bits to one of four frequencies.
  Uint8List modulate(Uint8List data) {
    final int samplesPerSymbol = (sampleRate / symbolRate).round();
    final int totalSymbols = data.length * 4; // each byte → 4 symbols
    final Int16List pcm = Int16List(totalSymbols * samplesPerSymbol);
    int pcmIndex = 0;
    for (var byte in data) {
      for (int s = 0; s < 4; s++) {
        int twoBits = (byte >> (s * 2)) & 0x03;
        double freq = frequencies[twoBits];
        for (int n = 0; n < samplesPerSymbol; n++) {
          double t = n / sampleRate;
          pcm[pcmIndex++] = (32767 * sin(2 * pi * freq * t)).toInt();
        }
      }
    }
    return pcm.buffer.asUint8List();
  }

  /// Demodulate a buffer of PCM samples into raw data bytes.
  ///
  /// Uses Goertzel or FFT-based detection to determine active tone per symbol.
  Uint8List demodulate(Uint8List samples) {
    final int samplesPerSymbol = (sampleRate / symbolRate).round();
    // detect one symbol per block
    final List<int> symbols = [];
    for (int i = 0; i < samples.length; i += samplesPerSymbol) {
      int end = i + samplesPerSymbol;
      if (end > samples.length) break;
      final block = samples.sublist(i, end);
      double maxP = double.negativeInfinity;
      int bestIdx = 0;
      for (int fIdx = 0; fIdx < 4; fIdx++) {
        final detector = _Goertzel(
          sampleRate: sampleRate,
          blockSize: samplesPerSymbol,
          targetFreq: frequencies[fIdx],
        );
        double p = detector.process(block);
        if (p > maxP) {
          maxP = p;
          bestIdx = fIdx;
        }
      }
      symbols.add(bestIdx);
    }
    // pack 4 symbols (2 bits each) into one byte
    final List<int> output = [];
    for (int i = 0; i + 3 < symbols.length; i += 4) {
      int b = 0;
      for (int j = 0; j < 4; j++) {
        b |= (symbols[i + j] & 0x03) << (j * 2);
      }
      output.add(b);
    }
    return Uint8List.fromList(output);
  }
}

/// Simple Goertzel detector for power at one frequency
class _Goertzel {
  final int sampleRate;
  final int blockSize;
  final double targetFreq;
  final double coeff;
  double _sPrev = 0.0;
  double _sPrev2 = 0.0;

  _Goertzel({
    required this.sampleRate,
    required this.blockSize,
    required this.targetFreq,
  }) : coeff = 2 * cos(2 * pi * targetFreq / sampleRate);

  double process(Uint8List samples) {
    _sPrev = 0.0;
    _sPrev2 = 0.0;
    for (int i = 0; i < blockSize; i++) {
      double sample = samples[i].toDouble();
      double s = sample + coeff * _sPrev - _sPrev2;
      _sPrev2 = _sPrev;
      _sPrev = s;
    }
    return _sPrev2 * _sPrev2 + _sPrev * _sPrev - coeff * _sPrev * _sPrev2;
  }
}
