import 'dart:typed_data';
import 'package:flutter/material.dart';

enum PlacementType { signature, highlight }

/// Interactive dialog allowing users to drag and position signatures or highlights across a page
class PdfElementPlacementDialog extends StatefulWidget {
  final Size pageSize; // PDF points (e.g., 595 x 842)
  final int pageNumber;
  final PlacementType type;
  final Uint8List? signatureBytes;
  final String? noteText;
  final Size defaultElementSize;

  const PdfElementPlacementDialog({
    super.key,
    required this.pageSize,
    required this.pageNumber,
    required this.type,
    this.signatureBytes,
    this.noteText,
    this.defaultElementSize = const Size(160, 60),
  });

  @override
  State<PdfElementPlacementDialog> createState() =>
      _PdfElementPlacementDialogState();
}

class _PdfElementPlacementDialogState extends State<PdfElementPlacementDialog> {
  // Coordinates in PDF points
  late double _pdfX;
  late double _pdfY;
  late double _pdfWidth;
  late double _pdfHeight;

  // Canvas size for preview in dialog
  final double _maxPreviewHeight = 360.0;
  late double _previewWidth;
  late double _previewHeight;
  late double _scaleFactor; // preview pixels / pdf points

  @override
  void initState() {
    super.initState();
    _pdfWidth = widget.defaultElementSize.width;
    _pdfHeight = widget.defaultElementSize.height;

    // Calculate preview canvas scale preserving PDF aspect ratio
    final pageRatio = widget.pageSize.width / widget.pageSize.height;
    _previewHeight = _maxPreviewHeight;
    _previewWidth = _previewHeight * pageRatio;
    if (_previewWidth > 260) {
      _previewWidth = 260;
      _previewHeight = _previewWidth / pageRatio;
    }
    _scaleFactor = _previewHeight / widget.pageSize.height;

    // Default position:
    // Signature: bottom-right
    // Highlight: top-middle
    if (widget.type == PlacementType.signature) {
      _pdfX = widget.pageSize.width - _pdfWidth - 40;
      _pdfY = widget.pageSize.height - _pdfHeight - 80;
    } else {
      _pdfX = 40;
      _pdfY = 120;
      _pdfWidth = widget.pageSize.width - 80;
      _pdfHeight = 35;
    }

    _clampCoordinates();
  }

  void _clampCoordinates() {
    _pdfX = _pdfX.clamp(0.0, widget.pageSize.width - _pdfWidth);
    _pdfY = _pdfY.clamp(0.0, widget.pageSize.height - _pdfHeight);
  }

  void _setPreset(String preset) {
    setState(() {
      switch (preset) {
        case 'bottom_right':
          _pdfX = widget.pageSize.width - _pdfWidth - 36;
          _pdfY = widget.pageSize.height - _pdfHeight - 60;
          break;
        case 'bottom_left':
          _pdfX = 36;
          _pdfY = widget.pageSize.height - _pdfHeight - 60;
          break;
        case 'center':
          _pdfX = (widget.pageSize.width - _pdfWidth) / 2;
          _pdfY = (widget.pageSize.height - _pdfHeight) / 2;
          break;
        case 'top_right':
          _pdfX = widget.pageSize.width - _pdfWidth - 36;
          _pdfY = 60;
          break;
        case 'top_left':
          _pdfX = 36;
          _pdfY = 60;
          break;
      }
      _clampCoordinates();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Current element position on screen canvas
    final previewElementX = _pdfX * _scaleFactor;
    final previewElementY = _pdfY * _scaleFactor;
    final previewElementW = _pdfWidth * _scaleFactor;
    final previewElementH = _pdfHeight * _scaleFactor;

    final isSig = widget.type == PlacementType.signature;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    isSig ? 'Position Signature' : 'Position Highlight',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Page ${widget.pageNumber}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Drag the box across the page to position it',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 12),

              // Interactive Page Preview Box
              Center(
                child: Container(
                  width: _previewWidth,
                  height: _previewHeight,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.grey.shade400, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      // Page watermark / guidelines
                      Positioned.fill(
                        child: Center(
                          child: Opacity(
                            opacity: 0.08,
                            child: Icon(Icons.description, size: _previewWidth * 0.6),
                          ),
                        ),
                      ),

                      // Draggable Element
                      Positioned(
                        left: previewElementX,
                        top: previewElementY,
                        width: previewElementW,
                        height: previewElementH,
                        child: GestureDetector(
                          onPanUpdate: (details) {
                            setState(() {
                              _pdfX += details.delta.dx / _scaleFactor;
                              _pdfY += details.delta.dy / _scaleFactor;
                              _clampCoordinates();
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSig
                                  ? Colors.blue.withValues(alpha: 0.15)
                                  : Colors.amber.withValues(alpha: 0.4),
                              border: Border.all(
                                color: isSig ? Colors.blue.shade700 : Colors.amber.shade800,
                                width: 1.5,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: isSig
                                ? (widget.signatureBytes != null
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: Image.memory(
                                          widget.signatureBytes!,
                                          fit: BoxFit.contain,
                                        ),
                                      )
                                    : const Center(
                                        child: Text(
                                          'Signature',
                                          style: TextStyle(fontSize: 10, color: Colors.blue),
                                        ),
                                      ))
                                : Center(
                                    child: Text(
                                      widget.noteText ?? 'Highlight',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // Position coordinates feedback
              Text(
                'Position: X: ${_pdfX.round()} pt, Y: ${_pdfY.round()} pt  (Size: ${_pdfWidth.round()}x${_pdfHeight.round()})',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontFamily: 'monospace'),
              ),

              const SizedBox(height: 8),

              // Quick Presets
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ActionChip(
                      label: const Text('Bottom Right', style: TextStyle(fontSize: 11)),
                      onPressed: () => _setPreset('bottom_right'),
                    ),
                    const SizedBox(width: 4),
                    ActionChip(
                      label: const Text('Bottom Left', style: TextStyle(fontSize: 11)),
                      onPressed: () => _setPreset('bottom_left'),
                    ),
                    const SizedBox(width: 4),
                    ActionChip(
                      label: const Text('Center', style: TextStyle(fontSize: 11)),
                      onPressed: () => _setPreset('center'),
                    ),
                    const SizedBox(width: 4),
                    ActionChip(
                      label: const Text('Top Left', style: TextStyle(fontSize: 11)),
                      onPressed: () => _setPreset('top_left'),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Scale Adjustment slider
              Row(
                children: [
                  const Text('Size: ', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _pdfWidth,
                      min: 80,
                      max: widget.pageSize.width - 20,
                      divisions: 15,
                      label: '${_pdfWidth.round()} pt',
                      onChanged: (val) {
                        setState(() {
                          final ratio = _pdfHeight / _pdfWidth;
                          _pdfWidth = val;
                          if (isSig) {
                            _pdfHeight = _pdfWidth * ratio;
                          }
                          _clampCoordinates();
                        });
                      },
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 8),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      final rect = Rect.fromLTWH(
                        _pdfX,
                        _pdfY,
                        _pdfWidth,
                        _pdfHeight,
                      );
                      Navigator.pop(context, rect);
                    },
                    child: Text(isSig ? 'Stamp Signature' : 'Apply Highlight'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
