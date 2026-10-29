import 'package:flutter/material.dart';
import 'dart:async'; // for Timer

import 'package:every_ai/models/global-resource/app_colors.dart';
import 'package:every_ai/models/cache-management/cache_schema.dart';

class ChatHistoryWidget extends StatefulWidget {
  final Function(int) onPressed;

  const ChatHistoryWidget({
    super.key,
    required this.onPressed,
  });

  State<ChatHistoryWidget> createState() => _ChatHistoryWidgetState();
}

class _ChatHistoryWidgetState extends State<ChatHistoryWidget> {
  // Create the logic object as a ChangeNotifier
  late final ChatHistoryWidgetLogic logic = ChatHistoryWidgetLogic();

  Timer? _timer; // To periodically fetch IDs

  @override
  void initState() {
    super.initState();

    // Listen to updates from the logic
    logic.addListener(() {
      // Every time logic calls notifyListeners(),
      // rebuild this widget to reflect updated data.
      setState(() {});
    });

    // Fetch once on startup
    logic.fetchAndPrintChatIDs();

    // Optionally: if you want frequent updates, use a Timer
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
      logic.fetchAndPrintChatIDs();
    });
  }

  @override
  void dispose() {
    // Cancel the timer to avoid memory leaks
    _timer?.cancel();
    // Remove the listener as well
    logic.removeListener(() {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 270,
      height: MediaQuery.of(context).size.height - 534,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: AppColors.primary,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'Chat History',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontSize: 16,
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: logic.idList.length,
                itemBuilder: (context, index) {
                  final currentID = logic.idList[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              widget.onPressed(currentID);
                            },
                            child: Text(
                              'Chat $currentID',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                color: Colors.white70,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () async {
                            await logic.deleteChat(currentID);
                          },
                          icon: const Icon(
                            Icons.delete,
                            color: Colors.white,
                          ),
                        )
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatHistoryWidgetLogic extends ChangeNotifier {
  final cache = CacheSchema.instance;

  List<int> idList = [];

  // Async method to fetch and update chat IDs
  Future<void> fetchAndPrintChatIDs() async {
    try {
      final newIds = await cache.fetchChatIDs(); // Fetch chat IDs
      idList = newIds;
      print('Chat IDs: $idList');
      // Notify all listeners (in this case, the widget) that data changed
      notifyListeners();
    } catch (e) {
      print('Error fetching chat IDs: $e');
    }
  }

  Future<void> deleteChat(int chatId) async {
    try {
      await cache.deleteChatById(chatId);
      // Now that the chat is deleted, re-fetch the IDs
      await fetchAndPrintChatIDs();
      // That will call notifyListeners(),
      // which triggers setState() in the widget
    } catch (e) {
      print('Error deleting chat $chatId: $e');
    }
  }
}