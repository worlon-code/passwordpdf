import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  final double size;
  final bool withText;
  final Color? color;

  const AppLogo({
    super.key, 
    this.size = 100,
    this.withText = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Proportional dimensions
    final cornerSize = size * 0.25;
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size * 0.8,
          height: size,
          child: Stack(
            children: [
              // Main Document Body (Rounded Rect)
              Container(
                decoration: BoxDecoration(
                  color: color ?? const Color(0xFF6200EA), // Deep Violet (Material Expressive)
                  borderRadius: BorderRadius.circular(size * 0.15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: size * 0.1,
                      offset: Offset(0, size * 0.05),
                    ),
                  ],
                ),
              ),
              
              // Folded Corner (Top Right)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  width: cornerSize,
                  height: cornerSize,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.3), // Lighter fold
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(size * 0.1),
                      topRight: Radius.circular(size * 0.15),
                    ),
                  ),
                ),
              ),
              
              // Center Icon (Shield Lock)
              Center(
                child: Icon(
                  Icons.lock_outline_rounded,
                  color: Colors.white,
                  size: size * 0.4,
                ),
              ),
            ],
          ),
        ),
        
        if (withText) ...[
          SizedBox(height: size * 0.2),
          Text(
            'PDF Manager',
            style: TextStyle(
              fontSize: size * 0.2,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ],
    );
  }
}
