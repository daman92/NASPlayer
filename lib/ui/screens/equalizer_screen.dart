import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/equalizer_provider.dart';

/// EQ and audio enhancement settings (design Phase 3).
class EqualizerScreen extends ConsumerWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eq = ref.watch(equalizerProvider);
    final notifier = ref.read(equalizerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Equalizer'),
        actions: [
          if (eq.available)
            TextButton(
              onPressed: notifier.reset,
              child: const Text('Reset'),
            ),
        ],
      ),
      body: !eq.available
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Equalizer is not available. Start playing a track first — '
                  'the equalizer attaches to the active audio session.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('Enable equalizer'),
                  value: eq.enabled,
                  onChanged: notifier.setEnabled,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 320,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: eq.bands
                          .map((band) => _BandSlider(
                                band: band,
                                enabled: eq.enabled,
                                onChanged: (gain) =>
                                    notifier.setBandGain(band.index, gain),
                              ))
                          .toList(),
                    ),
                  ),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Loudness enhancer'),
                  subtitle: const Text('Boost overall volume'),
                  value: eq.loudnessEnabled,
                  onChanged: notifier.setLoudnessEnabled,
                ),
                if (eq.loudnessEnabled)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text('Gain'),
                        Expanded(
                          child: Slider(
                            value: eq.loudnessGain.clamp(0, 1),
                            onChanged: notifier.setLoudnessGain,
                          ),
                        ),
                        Text('${(eq.loudnessGain * 100).round()}%'),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  final EqBand band;
  final bool enabled;
  final ValueChanged<double> onChanged;

  const _BandSlider({
    required this.band,
    required this.enabled,
    required this.onChanged,
  });

  String get _freqLabel {
    final hz = band.centerFrequency;
    if (hz >= 1000) {
      final khz = hz / 1000;
      return '${khz % 1 == 0 ? khz.toInt() : khz.toStringAsFixed(1)}k';
    }
    return hz.toInt().toString();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('${band.gain.toStringAsFixed(1)}dB',
            style: Theme.of(context).textTheme.bodySmall),
        Expanded(
          child: RotatedBox(
            quarterTurns: -1,
            child: Slider(
              value: band.gain.clamp(band.minGain, band.maxGain),
              min: band.minGain,
              max: band.maxGain,
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ),
        Text(_freqLabel, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
