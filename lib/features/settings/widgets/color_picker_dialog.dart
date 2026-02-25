import 'package:flutter/material.dart';
import '../services/settings_service.dart';

/// HSV Color Picker Dialog with gradient selector, hue bar, and hex input
class ColorPickerDialog extends StatefulWidget {
  final SettingsService settings;

  const ColorPickerDialog({super.key, required this.settings});

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late HSVColor _hsvColor;
  late TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    _hsvColor = HSVColor.fromColor(widget.settings.accentColor);
    _hexController = TextEditingController(
      text: _colorToHex(widget.settings.accentColor),
    );
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _colorToHex(Color color) {
    return color.value.toRadixString(16).substring(2).toUpperCase();
  }

  void _updateFromHex(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      try {
        final color = Color(int.parse('FF$hex', radix: 16));
        setState(() {
          _hsvColor = HSVColor.fromColor(color);
        });
      } catch (_) {}
    }
  }

  void _updateHexField() {
    _hexController.text = _colorToHex(_hsvColor.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final currentColor = _hsvColor.toColor();

    return AlertDialog(
      title: const Text('Choose Color'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Saturation-Value Picker
            GestureDetector(
              onPanUpdate: (details) {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null) return;
                final localPos = details.localPosition;
                final s = (localPos.dx / 260).clamp(0.0, 1.0);
                final v = 1.0 - (localPos.dy / 180).clamp(0.0, 1.0);
                setState(() {
                  _hsvColor = _hsvColor.withSaturation(s).withValue(v);
                  _updateHexField();
                });
              },
              onTapDown: (details) {
                final localPos = details.localPosition;
                final s = (localPos.dx / 260).clamp(0.0, 1.0);
                final v = 1.0 - (localPos.dy / 180).clamp(0.0, 1.0);
                setState(() {
                  _hsvColor = _hsvColor.withSaturation(s).withValue(v);
                  _updateHexField();
                });
              },
              child: Container(
                width: 260,
                height: 180,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: LinearGradient(
                    colors: [
                      Colors.white,
                      HSVColor.fromAHSV(1, _hsvColor.hue, 1, 1).toColor(),
                    ],
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black],
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: _hsvColor.saturation * 260 - 10,
                        top: (1 - _hsvColor.value) * 180 - 10,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Hue Slider
            GestureDetector(
              onPanUpdate: (details) {
                final h = (details.localPosition.dx / 260 * 360).clamp(0.0, 360.0);
                setState(() {
                  _hsvColor = _hsvColor.withHue(h);
                  _updateHexField();
                });
              },
              onTapDown: (details) {
                final h = (details.localPosition.dx / 260 * 360).clamp(0.0, 360.0);
                setState(() {
                  _hsvColor = _hsvColor.withHue(h);
                  _updateHexField();
                });
              },
              child: Container(
                width: 260,
                height: 20,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFFFF0000),
                      Color(0xFFFFFF00),
                      Color(0xFF00FF00),
                      Color(0xFF00FFFF),
                      Color(0xFF0000FF),
                      Color(0xFFFF00FF),
                      Color(0xFFFF0000),
                    ],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: (_hsvColor.hue / 360) * 260 - 10,
                      top: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: HSVColor.fromAHSV(1, _hsvColor.hue, 1, 1).toColor(),
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Hex Input Row
            Row(
              children: [
                const Text('HEX'),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () {
                    _updateHexField();
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _hexController,
                    decoration: const InputDecoration(
                      prefixText: '#',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    maxLength: 6,
                    buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                    onChanged: _updateFromHex,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Color Preview
            Container(
              width: double.infinity,
              height: 60,
              decoration: BoxDecoration(
                color: currentColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  '#${_colorToHex(currentColor)}',
                  style: TextStyle(
                    color: _hsvColor.value > 0.5 ? Colors.black : Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            widget.settings.setAccentColor(currentColor);
            Navigator.pop(context);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
