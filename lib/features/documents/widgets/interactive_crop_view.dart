import 'dart:io';
import 'package:flutter/material.dart';

/// Interactive document cropping widget with free-flow 4-point quadrilateral handles
/// Matching Adobe Scan perspective/skew boundary adjustment standard
class InteractiveCropView extends StatefulWidget {
  final File imageFile;
  final List<Offset>? initialQuad; // 4 normalized points: [tl, tr, br, bl]
  final Rect? initialNormalizedRect; // Fallback
  final ValueChanged<List<Offset>> onQuadChanged;
  final ValueChanged<Rect>? onCropChanged;

  const InteractiveCropView({
    super.key,
    required this.imageFile,
    this.initialQuad,
    this.initialNormalizedRect,
    required this.onQuadChanged,
    this.onCropChanged,
  });

  @override
  State<InteractiveCropView> createState() => _InteractiveCropViewState();
}

class _InteractiveCropViewState extends State<InteractiveCropView> {
  late Offset _tl;
  late Offset _tr;
  late Offset _br;
  late Offset _bl;
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _initPoints();
    _resolveImageDimensions();
  }

  void _initPoints() {
    if (widget.initialQuad != null && widget.initialQuad!.length == 4) {
      _tl = widget.initialQuad![0];
      _tr = widget.initialQuad![1];
      _br = widget.initialQuad![2];
      _bl = widget.initialQuad![3];
    } else if (widget.initialNormalizedRect != null) {
      final r = widget.initialNormalizedRect!;
      _tl = Offset(r.left, r.top);
      _tr = Offset(r.right, r.top);
      _br = Offset(r.right, r.bottom);
      _bl = Offset(r.left, r.bottom);
    } else {
      _tl = const Offset(0.04, 0.04);
      _tr = const Offset(0.96, 0.04);
      _br = const Offset(0.96, 0.96);
      _bl = const Offset(0.04, 0.96);
    }
  }

  @override
  void didUpdateWidget(covariant InteractiveCropView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageFile.path != widget.imageFile.path) {
      _resolveImageDimensions();
    }
    if (oldWidget.initialQuad != widget.initialQuad && widget.initialQuad != null) {
      setState(() {
        _tl = widget.initialQuad![0];
        _tr = widget.initialQuad![1];
        _br = widget.initialQuad![2];
        _bl = widget.initialQuad![3];
      });
    }
  }

  void _resolveImageDimensions() {
    final imageProvider = FileImage(widget.imageFile);
    imageProvider.resolve(const ImageConfiguration()).addListener(
      ImageStreamListener((ImageInfo info, bool _) {
        if (mounted) {
          setState(() {
            _imageSize = Size(
              info.image.width.toDouble(),
              info.image.height.toDouble(),
            );
          });
        }
      }),
    );
  }

  void _notifyChange() {
    final quad = [_tl, _tr, _br, _bl];
    widget.onQuadChanged(quad);

    if (widget.onCropChanged != null) {
      final minX = [_tl.dx, _tr.dx, _br.dx, _bl.dx].reduce((a, b) => a < b ? a : b);
      final maxX = [_tl.dx, _tr.dx, _br.dx, _bl.dx].reduce((a, b) => a > b ? a : b);
      final minY = [_tl.dy, _tr.dy, _br.dy, _bl.dy].reduce((a, b) => a < b ? a : b);
      final maxY = [_tl.dy, _tr.dy, _br.dy, _bl.dy].reduce((a, b) => a > b ? a : b);
      widget.onCropChanged!(Rect.fromLTRB(minX, minY, maxX, maxY));
    }
  }

  Offset _clampOffset(Offset pt) {
    return Offset(pt.dx.clamp(0.0, 1.0), pt.dy.clamp(0.0, 1.0));
  }

  Rect _calculateRenderRect(Size containerSize) {
    if (_imageSize == null || _imageSize!.width == 0 || _imageSize!.height == 0) {
      return Rect.fromLTWH(0, 0, containerSize.width, containerSize.height);
    }
    final fitted = applyBoxFit(BoxFit.contain, _imageSize!, containerSize);
    return Alignment.center.inscribe(
      fitted.destination,
      Rect.fromLTWH(0, 0, containerSize.width, containerSize.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final containerSize = Size(constraints.maxWidth, constraints.maxHeight);
        final renderRect = _calculateRenderRect(containerSize);

        return Stack(
          children: [
            // Centered Image fitted strictly within contain
            Positioned.fromRect(
              rect: renderRect,
              child: Image.file(
                widget.imageFile,
                fit: BoxFit.fill,
              ),
            ),

            // Draggable Free-Flow Quadrilateral Overlay
            Positioned.fromRect(
              rect: renderRect,
              child: CustomPaint(
                painter: _QuadCropOverlayPainter(
                  tl: _tl,
                  tr: _tr,
                  br: _br,
                  bl: _bl,
                  accentColor: primaryColor,
                ),
              ),
            ),

            // Interactive Handles positioned strictly relative to image render rect
            Positioned.fromRect(
              rect: renderRect,
              child: _buildHandles(renderRect.width, renderRect.height),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHandles(double w, double h) {
    final tlPx = Offset(_tl.dx * w, _tl.dy * h);
    final trPx = Offset(_tr.dx * w, _tr.dy * h);
    final brPx = Offset(_br.dx * w, _br.dy * h);
    final blPx = Offset(_bl.dx * w, _bl.dy * h);

    const cornerSize = 48.0;
    const halfCorner = cornerSize / 2;

    // Edge midpoints
    final topMid = (tlPx + trPx) / 2;
    final rightMid = (trPx + brPx) / 2;
    final bottomMid = (brPx + blPx) / 2;
    final leftMid = (blPx + tlPx) / 2;

    // Center pan point
    final center = (tlPx + trPx + brPx + blPx) / 4;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Pan entire quadrilateral from center
        Positioned(
          left: center.dx - 40,
          top: center.dy - 40,
          width: 80,
          height: 80,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (details) {
              final dx = details.delta.dx / w;
              final dy = details.delta.dy / h;
              setState(() {
                _tl = _clampOffset(_tl + Offset(dx, dy));
                _tr = _clampOffset(_tr + Offset(dx, dy));
                _br = _clampOffset(_br + Offset(dx, dy));
                _bl = _clampOffset(_bl + Offset(dx, dy));
              });
              _notifyChange();
            },
          ),
        ),

        // 1. Top-Left Corner Handle (Free Flow)
        Positioned(
          left: tlPx.dx - halfCorner,
          top: tlPx.dy - halfCorner,
          child: _buildCornerHandle(
            onPanUpdate: (dx, dy) {
              setState(() {
                _tl = _clampOffset(_tl + Offset(dx / w, dy / h));
              });
              _notifyChange();
            },
          ),
        ),

        // 2. Top-Right Corner Handle (Free Flow)
        Positioned(
          left: trPx.dx - halfCorner,
          top: trPx.dy - halfCorner,
          child: _buildCornerHandle(
            onPanUpdate: (dx, dy) {
              setState(() {
                _tr = _clampOffset(_tr + Offset(dx / w, dy / h));
              });
              _notifyChange();
            },
          ),
        ),

        // 3. Bottom-Right Corner Handle (Free Flow)
        Positioned(
          left: brPx.dx - halfCorner,
          top: brPx.dy - halfCorner,
          child: _buildCornerHandle(
            onPanUpdate: (dx, dy) {
              setState(() {
                _br = _clampOffset(_br + Offset(dx / w, dy / h));
              });
              _notifyChange();
            },
          ),
        ),

        // 4. Bottom-Left Corner Handle (Free Flow)
        Positioned(
          left: blPx.dx - halfCorner,
          top: blPx.dy - halfCorner,
          child: _buildCornerHandle(
            onPanUpdate: (dx, dy) {
              setState(() {
                _bl = _clampOffset(_bl + Offset(dx / w, dy / h));
              });
              _notifyChange();
            },
          ),
        ),

        // 5. Top Edge Midpoint Bar Handle
        Positioned(
          left: topMid.dx - 22,
          top: topMid.dy - 16,
          child: _buildEdgeHandle(
            isVertical: false,
            onPanUpdate: (dx, dy) {
              setState(() {
                final d = Offset(dx / w, dy / h);
                _tl = _clampOffset(_tl + d);
                _tr = _clampOffset(_tr + d);
              });
              _notifyChange();
            },
          ),
        ),

        // 6. Right Edge Midpoint Bar Handle
        Positioned(
          left: rightMid.dx - 16,
          top: rightMid.dy - 22,
          child: _buildEdgeHandle(
            isVertical: true,
            onPanUpdate: (dx, dy) {
              setState(() {
                final d = Offset(dx / w, dy / h);
                _tr = _clampOffset(_tr + d);
                _br = _clampOffset(_br + d);
              });
              _notifyChange();
            },
          ),
        ),

        // 7. Bottom Edge Midpoint Bar Handle
        Positioned(
          left: bottomMid.dx - 22,
          top: bottomMid.dy - 16,
          child: _buildEdgeHandle(
            isVertical: false,
            onPanUpdate: (dx, dy) {
              setState(() {
                final d = Offset(dx / w, dy / h);
                _bl = _clampOffset(_bl + d);
                _br = _clampOffset(_br + d);
              });
              _notifyChange();
            },
          ),
        ),

        // 8. Left Edge Midpoint Bar Handle
        Positioned(
          left: leftMid.dx - 16,
          top: leftMid.dy - 22,
          child: _buildEdgeHandle(
            isVertical: true,
            onPanUpdate: (dx, dy) {
              setState(() {
                final d = Offset(dx / w, dy / h);
                _tl = _clampOffset(_tl + d);
                _bl = _clampOffset(_bl + d);
              });
              _notifyChange();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCornerHandle({required void Function(double dx, double dy) onPanUpdate}) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => onPanUpdate(details.delta.dx, details.delta.dy),
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.35),
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.primary, width: 3.5),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 1)),
            ],
          ),
          child: Center(
            child: Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEdgeHandle({
    required bool isVertical,
    required void Function(double dx, double dy) onPanUpdate,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => onPanUpdate(details.delta.dx, details.delta.dy),
      child: Container(
        width: isVertical ? 32 : 44,
        height: isVertical ? 44 : 32,
        alignment: Alignment.center,
        child: Container(
          width: isVertical ? 8 : 26,
          height: isVertical ? 26 : 8,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colorScheme.primary, width: 2.2),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Painter for dimming the area outside the quadrilateral and drawing perspective boundary lines
class _QuadCropOverlayPainter extends CustomPainter {
  final Offset tl;
  final Offset tr;
  final Offset br;
  final Offset bl;
  final Color accentColor;

  _QuadCropOverlayPainter({
    required this.tl,
    required this.tr,
    required this.br,
    required this.bl,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final tlPx = Offset(tl.dx * size.width, tl.dy * size.height);
    final trPx = Offset(tr.dx * size.width, tr.dy * size.height);
    final brPx = Offset(br.dx * size.width, br.dy * size.height);
    final blPx = Offset(bl.dx * size.width, bl.dy * size.height);

    // Quad polygon path
    final quadPath = Path()
      ..moveTo(tlPx.dx, tlPx.dy)
      ..lineTo(trPx.dx, trPx.dy)
      ..lineTo(brPx.dx, brPx.dy)
      ..lineTo(blPx.dx, blPx.dy)
      ..close();

    // Darken exterior
    final fullRectPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final scrimPath = Path.combine(PathOperation.difference, fullRectPath, quadPath);
    final scrimPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.60)
      ..style = PaintingStyle.fill;
    canvas.drawPath(scrimPath, scrimPaint);

    // Boundary Lines
    final borderPaint = Paint()
      ..color = accentColor
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke;
    canvas.drawPath(quadPath, borderPaint);

    // Internal Perspective Alignment Grid Lines (Rule of Thirds)
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // 1/3 and 2/3 along top and bottom
    final top1 = Offset.lerp(tlPx, trPx, 1 / 3)!;
    final top2 = Offset.lerp(tlPx, trPx, 2 / 3)!;
    final bot1 = Offset.lerp(blPx, brPx, 1 / 3)!;
    final bot2 = Offset.lerp(blPx, brPx, 2 / 3)!;

    canvas.drawLine(top1, bot1, gridPaint);
    canvas.drawLine(top2, bot2, gridPaint);

    // 1/3 and 2/3 along left and right
    final left1 = Offset.lerp(tlPx, blPx, 1 / 3)!;
    final left2 = Offset.lerp(tlPx, blPx, 2 / 3)!;
    final right1 = Offset.lerp(trPx, brPx, 1 / 3)!;
    final right2 = Offset.lerp(trPx, brPx, 2 / 3)!;

    canvas.drawLine(left1, right1, gridPaint);
    canvas.drawLine(left2, right2, gridPaint);
  }

  @override
  bool shouldRepaint(covariant _QuadCropOverlayPainter oldDelegate) {
    return oldDelegate.tl != tl ||
        oldDelegate.tr != tr ||
        oldDelegate.br != br ||
        oldDelegate.bl != bl ||
        oldDelegate.accentColor != accentColor;
  }
}
