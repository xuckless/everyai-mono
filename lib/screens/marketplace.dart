import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/chat_models.dart';
import 'package:second_times_the_charm/widgets/app-bar-widgets/default_app_bar.dart';

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

  void _toggleModel(String model){
    setState(() {
      toggleModelStatus(model);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181C26),
      appBar: DefaultAppBar(
        popUpText: '',
      ),
      body: Stack(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: chatModels
                  .where((model) => !chatModelAddedStatus[model['name']]!)
                  .length,
              itemBuilder: (context, index) {
                final model = chatModels
                    .where((model) => !chatModelAddedStatus[model['name']]!)
                    .toList()[index];
                return ListTile(
                  leading: Image.asset(
                    model['picture'],
                    width: 50,
                    height: 50,
                  ),
                  title: Text(
                    model['name'],
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: ElevatedButton(
                    onPressed: () => _toggleModel(model['name']),
                    child: const Icon(Icons.add),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }}