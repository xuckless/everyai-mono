import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/default_app_bar.dart';

class Marketplace extends StatefulWidget{
  final String title;

  const Marketplace({
    required this.title,
    super.key
  });

  @override
  State<Marketplace> createState() => _MarketplaceState();
}


class _MarketplaceState extends State<Marketplace>{

  Widget build(BuildContext context){
    return Scaffold(
      appBar: DefaultAppBar(subtitle: 'Marketplace'),
    );
  }
}