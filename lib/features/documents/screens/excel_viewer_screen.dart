import 'package:flutter/material.dart';

class ExcelViewerScreen extends StatelessWidget {
  final String filePath;
  final String fileName;
  const ExcelViewerScreen({super.key, required this.filePath, required this.fileName});

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(fileName)));
}
