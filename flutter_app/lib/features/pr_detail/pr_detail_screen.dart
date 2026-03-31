import 'package:flutter/material.dart';

class PRDetailScreen extends StatelessWidget {
  final int prId;

  const PRDetailScreen({super.key, required this.prId});

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('PR $prId')));
}
