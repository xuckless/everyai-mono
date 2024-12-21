import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/chat_models.dart';
import 'package:second_times_the_charm/widgets/app-bar-widgets/default_app_bar.dart';

import '../widgets/sort-by-section/sort_model.dart';

class Marketplace extends StatefulWidget {
  final String title;

  const Marketplace({
    required this.title,
    super.key,
  });

  @override
  State<Marketplace> createState() => _MarketplaceState();
}

class _MarketplaceState extends State<Marketplace> {
  List<Map<String, dynamic>> _filteredModels = chatModels;

  @override
  void initState() {
    super.initState();
    _filterModels("All");  // Default filter when the screen loads
  }

  void _filterModels(String filter) {
    setState(() {
      if (filter == "All") {
        _filteredModels = chatModels;
      } else {
        _filteredModels = chatModels
            .where((model) => model['category'] == filter)
            .toList();
      }
    });
  }

  void _toggleModel(String model) {
    setState(() {
      toggleModelStatus(model);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181C26),
      appBar: DefaultAppBar(
        title: "Marketplace",
        popUpText: '',
      ),
      body: Column(
        children: [
          // Add SortModel here
          SortModel(
            filterOptions: ["All", "Text-To-Text", "Text-To-Image"],
            onFilterSelected: (filter) {
              _filterModels(filter);
            },
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredModels
                  .where((model) => !chatModelAddedStatus[model['name']]!)
                  .length,
              itemBuilder: (context, index) {
                final model = _filteredModels
                    .where((model) => !chatModelAddedStatus[model['name']]!)
                    .toList()[index];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(100),  // Add border radius
                    child: Image.asset(
                      model['picture'],
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,  // Ensures the image covers the entire space
                    ),
                  ),
                  title: Text(
                    model['name'],
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: ElevatedButton(
                    onPressed: () => _toggleModel(model['name']),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xFF2A3041),  // Background color
                      foregroundColor: Colors.white,       // Icon color
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),  // Rounded corners
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,  // Adjust vertical padding
                      ),
                      elevation: 5,  // Shadow for depth
                    ),
                    child: const Icon(
                      Icons.add,
                      size: 20,  // Icon size
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}