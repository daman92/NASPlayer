import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_provider.dart';
import 'library_provider.dart';

class EqBand {
  final int index;
  final double centerFrequency;
  final double minGain;
  final double maxGain;
  final double gain;

  const EqBand({
    required this.index,
    required this.centerFrequency,
    required this.minGain,
    required this.maxGain,
    required this.gain,
  });
}

class EqualizerState {
  final bool enabled;
  final bool loudnessEnabled;
  final double loudnessGain;
  final List<EqBand> bands;
  final bool available;

  const EqualizerState({
    this.enabled = false,
    this.loudnessEnabled = false,
    this.loudnessGain = 0,
    this.bands = const [],
    this.available = false,
  });

  EqualizerState copyWith({
    bool? enabled,
    bool? loudnessEnabled,
    double? loudnessGain,
    List<EqBand>? bands,
    bool? available,
  }) =>
      EqualizerState(
        enabled: enabled ?? this.enabled,
        loudnessEnabled: loudnessEnabled ?? this.loudnessEnabled,
        loudnessGain: loudnessGain ?? this.loudnessGain,
        bands: bands ?? this.bands,
        available: available ?? this.available,
      );
}

class EqualizerNotifier extends StateNotifier<EqualizerState> {
  final Ref _ref;

  EqualizerNotifier(this._ref) : super(const EqualizerState()) {
    _init();
  }

  Future<void> _init() async {
    final handler = _ref.read(audioHandlerProvider);
    final settings = _ref.read(settingsServiceProvider);

    try {
      final saved = await settings.getEqSettings();

      if (saved != null) {
        final enabled = saved['enabled'] as bool? ?? false;
        await handler.equalizer.setEnabled(enabled);
        final loudnessEnabled = saved['loudnessEnabled'] as bool? ?? false;
        final loudnessGain = (saved['loudnessGain'] as num?)?.toDouble() ?? 0;
        await handler.loudnessEnhancer.setEnabled(loudnessEnabled);
        await handler.loudnessEnhancer.setTargetGain(loudnessGain);
      }

      final params = await handler.equalizer.parameters;
      final savedGains = (saved?['gains'] as List?)?.cast<num>();

      final bands = <EqBand>[];
      for (var i = 0; i < params.bands.length; i++) {
        final band = params.bands[i];
        if (savedGains != null && i < savedGains.length) {
          await band.setGain(savedGains[i].toDouble().clamp(
                params.minDecibels,
                params.maxDecibels,
              ));
        }
        bands.add(EqBand(
          index: i,
          centerFrequency: band.centerFrequency,
          minGain: params.minDecibels,
          maxGain: params.maxDecibels,
          gain: band.gain,
        ));
      }

      state = EqualizerState(
        enabled: saved?['enabled'] as bool? ?? false,
        loudnessEnabled: saved?['loudnessEnabled'] as bool? ?? false,
        loudnessGain: (saved?['loudnessGain'] as num?)?.toDouble() ?? 0,
        bands: bands,
        available: true,
      );
    } catch (_) {
      // Equalizer parameters are only available on Android with an active
      // audio session; leave unavailable state.
      state = const EqualizerState(available: false);
    }
  }

  Future<void> setEnabled(bool enabled) async {
    final handler = _ref.read(audioHandlerProvider);
    await handler.equalizer.setEnabled(enabled);
    state = state.copyWith(enabled: enabled);
    await _persist();
  }

  Future<void> setBandGain(int index, double gain) async {
    final handler = _ref.read(audioHandlerProvider);
    final params = await handler.equalizer.parameters;
    if (index < 0 || index >= params.bands.length) return;
    await params.bands[index].setGain(gain);

    final bands = List<EqBand>.from(state.bands);
    if (index < bands.length) {
      final b = bands[index];
      bands[index] = EqBand(
        index: b.index,
        centerFrequency: b.centerFrequency,
        minGain: b.minGain,
        maxGain: b.maxGain,
        gain: gain,
      );
    }
    state = state.copyWith(bands: bands);
    await _persist();
  }

  Future<void> setLoudnessEnabled(bool enabled) async {
    final handler = _ref.read(audioHandlerProvider);
    await handler.loudnessEnhancer.setEnabled(enabled);
    state = state.copyWith(loudnessEnabled: enabled);
    await _persist();
  }

  Future<void> setLoudnessGain(double gain) async {
    final handler = _ref.read(audioHandlerProvider);
    await handler.loudnessEnhancer.setTargetGain(gain);
    state = state.copyWith(loudnessGain: gain);
    await _persist();
  }

  Future<void> reset() async {
    for (final band in state.bands) {
      await setBandGain(band.index, 0);
    }
  }

  Future<void> _persist() async {
    final settings = _ref.read(settingsServiceProvider);
    await settings.saveEqSettings({
      'enabled': state.enabled,
      'loudnessEnabled': state.loudnessEnabled,
      'loudnessGain': state.loudnessGain,
      'gains': state.bands.map((b) => b.gain).toList(),
    });
  }
}

final equalizerProvider =
    StateNotifierProvider<EqualizerNotifier, EqualizerState>((ref) {
  return EqualizerNotifier(ref);
});
