
import 'package:flutter/material.dart';
import '../models/sort_option.dart';

class SortBottomSheet extends StatefulWidget {
  final SortOption currentOption;
  final bool isAscending;
  final Function(SortOption option, bool ascending) onSortChanged;

  const SortBottomSheet({
    super.key,
    required this.currentOption,
    required this.isAscending,
    required this.onSortChanged,
  });

  @override
  State<SortBottomSheet> createState() => _SortBottomSheetState();
}

class _SortBottomSheetState extends State<SortBottomSheet> {
  late SortOption _selectedOption;
  late bool _isAscending;

  @override
  void initState() {
    super.initState();
    _selectedOption = widget.currentOption;
    _isAscending = widget.isAscending;
  }

  void _handleOptionTap(SortOption option) {
    setState(() {
      if (_selectedOption == option) {
        // Toggle direction if same option tapped
        _isAscending = !_isAscending;
      } else {
        // Select new option, default to ascending (or descending for dates if preferred, but keeping simple)
        _selectedOption = option;
        _isAscending = true;
        
        // Special case: Dates usually better descending by default?
        // For now adhering to simple toggle logic starting true
        if (option == SortOption.dateCreated || option == SortOption.dateModified) {
           _isAscending = false; // Default newest first for dates
        }
      }
    });
  }

  void _apply() {
    widget.onSortChanged(_selectedOption, _isAscending);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      // Use mainAxisSize min to wrap content (Moved to Column)
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                   Text(
                    'Sort By',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextButton(
                    onPressed: _apply, 
                    child: Text(
                      'Apply', 
                      style: TextStyle(
                        fontWeight: FontWeight.bold, 
                        color: Theme.of(context).colorScheme.primary, // Use colorScheme.primary which handles dark mode better
                        fontSize: 16,
                      ),
                    )
                  ),
                ],
              ),
            ),
            const Divider(),
            
            // Options
            ...SortOption.values.map((option) {
              final isSelected = _selectedOption == option;
              final textColor = isSelected 
                  ? Theme.of(context).colorScheme.primary 
                  : Theme.of(context).colorScheme.onSurface;

              return InkWell(
                onTap: () => _handleOptionTap(option),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    children: [
                      Icon(_getIconForOption(option), 
                        color: isSelected ? Theme.of(context).colorScheme.primary : Theme.of(context).iconTheme.color?.withOpacity(0.7) ?? Colors.grey
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          option.label,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: textColor,
                          ),
                        ),
                      ),
                      if (isSelected)
                        Icon(
                          _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                    ],
                  ),
                ),
              );
            }).toList(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  IconData _getIconForOption(SortOption option) {
    switch (option) {
      case SortOption.name: return Icons.sort_by_alpha;
      case SortOption.size: return Icons.data_usage;
      case SortOption.dateCreated: return Icons.calendar_today;
      case SortOption.dateModified: return Icons.history;
    }
  }
}
