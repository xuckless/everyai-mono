//./lib/screens/chat_screen.dart

import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/api_service.dart';
import 'package:second_times_the_charm/screens/home.dart';
import 'package:second_times_the_charm/widgets/chat_box.dart';

// ------------------------------

class ChatScreen extends StatefulWidget{
  final String title;

  const ChatScreen({super.key, required this.title});

  @override
  State<ChatScreen> createState() => _ChatScreenState();

}


// ----------------------------------

class _ChatScreenState extends State<ChatScreen>{

  final TextEditingController _messageController = TextEditingController();
  List<Map<String, dynamic>> _messages = [];

  final ApiService _apiService = ApiService();

  String suffix = "";


  final FocusNode _focusNode = FocusNode();

  void _sendMessage() async {
    if (_messageController.text.trim().isNotEmpty) {
      setState(() {
        _messages.add({
          'text': _messageController.text.trim(),
          'isSentByUser': true,
        });
        _messageController.clear();
        _focusNode.requestFocus();
      });

      try {
        final response;
        if (suffix != ""){
          response = await _apiService.d_chat(_messages.last['text'], suffix);
        }
        else{
          response = await _apiService.chat(_messages.last['text']);
        }

        _receiveMessage(response['message']);
      } catch (e) {
        print('Error occurred: $e'); // Print the error
        _receiveMessage("Error: Could not fetch response.");
      }
    }
    }

  void _setChat(String suffix) {
    setState(() {
      this.suffix = suffix;
    });
  }

  void _receiveMessage(String text){
    setState(() {
      _messages.add(
        {
          'text': text,
          'isSentByUser': false,
        }
      );
    });
    }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("EveryAI (Beta)"),
        backgroundColor: Theme
            .of(context)
            .colorScheme
            .inversePrimary,
        centerTitle: true,
        
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == "GPT-4o-mini"){
                _setChat("GPT-4o-mini");
              } else if (value == "GPT-3.5-turbo"){
                _setChat("GPT-3.5-turbo");
              }
            },
            itemBuilder: (BuildContext context){
              return [
                PopupMenuItem(
                  value: "GPT-4o-mini",
                  child: Text("GPT-4o-mini"),
                ),
                PopupMenuItem(
                  value: "GPT-3.5-turbo",
                  child: Text("GPT-3.5 Turbo"),
                ),
              ];
            },
          )
        ],
      ),


      body: Center(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                reverse: true,
                child: Container(
                  // height: MediaQuery.of(context).size.height ,
                  // width: MediaQuery.of(context).size.width,
                  color: Colors.transparent,
                  child: Column(
                    children: _messages.map((message) {
                      return ChatBox(message: message['text'], isSentByUser: message['isSentByUser'],
                      );
                    }).toList(),
                  ),
                ),
              )
            ),


            //bottom bar
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width,
                maxHeight: 150
              ),
              child: Container(
                // color: Colors.lightGreen,
                child: Row(
                  children: [
                    //chat box
                    Container(
                      width: MediaQuery.of(context).size.width - 70,
                      decoration: BoxDecoration(
                        // color: Colors.lime,
                        border: Border.all(
                          color: Colors.transparent,
                          width: 10.0,
                        )
                      ),
                      child: TextFormField(
                        controller: _messageController,
                        focusNode: _focusNode,
                        onFieldSubmitted: (text) {
                          _sendMessage();
                        },
                        decoration: InputDecoration(
                          fillColor: Theme.of(context).primaryColorLight,
                          labelText: "Chat",
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4.0)
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 70,
                      decoration: BoxDecoration(
                        // color: Colors.redAccent,
                        border: Border.all(
                          color: Colors.transparent,
                          width: 10,
                        )
                      ),
                      child: FloatingActionButton(
                        onPressed: _sendMessage,
                        child: Icon(Icons.arrow_upward),
                      ),
                    ),
                  ],
                )
              ),
            )
          ],
        ),
      ),
    );
  }
}