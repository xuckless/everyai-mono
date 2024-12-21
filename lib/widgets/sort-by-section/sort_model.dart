import 'package:flutter/material.dart';

/// A horizontally scrollable filter bar that allows users to select from a list of options.
///
/// This widget displays a list of filter options as horizontally scrollable text chips.
/// When a filter is selected, the text chip changes color to indicate selection.
/// The parent widget is notified of the selection through a callback.
class SortModel extends StatefulWidget {
  /// List of filter options to display in the horizontal filter bar.
  final List<String> filterOptions;

  /// Callback function that is triggered when a filter is selected.
  ///
  /// The selected filter (as a string) is passed to this function.
  final ValueChanged<String> onFilterSelected;

  /// Creates a [SortModel] widget.
  ///
  /// - [filterOptions]: A list of strings representing filter options.
  /// - [onFilterSelected]: Callback for notifying the parent widget of the selected filter.
  const SortModel({
    super.key,
    required this.filterOptions,
    required this.onFilterSelected,
  });

  @override
  State<SortModel> createState() => _SortModelState();
}

/// State class that manages the selection logic and rendering of the filter bar.
class _SortModelState extends State<SortModel> {
  /// The currently selected filter.
  ///
  /// Defaults to the first item in the [filterOptions] list if available.
  String _selectedFilter = "";

  @override
  void initState() {
    super.initState();
    // Automatically select the first filter option when the widget is initialized.
    _selectedFilter = widget.filterOptions.isNotEmpty
        ? widget.filterOptions[0]
        : ""; // Fallback to an empty string if no options are provided.
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,  // Enables horizontal scrolling.
        itemCount: widget.filterOptions.length,  // Number of filters to display.
        itemBuilder: (context, index) {
          final filter = widget.filterOptions[index];
          final isSelected = filter == _selectedFilter;  // Check if the filter is selected.

          return GestureDetector(
            onTap: () {
              // Update the selected filter and notify the parent widget of the change.
              setState(() {
                _selectedFilter = filter;
              });
              widget.onFilterSelected(filter);  // Trigger the callback.
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : const Color(0xFF2A3041),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,  // Ensures text is centered within the box.
              child: Text(
                filter,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF2A3041) : Colors.white,
                  fontSize: 16,  // Slightly larger font for better readability.
                  fontWeight: FontWeight.w500,
                  height: 1.2,  // Line height to prevent text clipping.
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}