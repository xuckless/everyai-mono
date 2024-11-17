import 'package:flutter/material.dart';
import 'package:second_times_the_charm/screens/home.dart';
import 'package:second_times_the_charm/widgets/chat_box.dart';

// ------------------------------

class ChatScreen extends StatefulWidget{
  final String title;

  const ChatScreen({super.key, required this.title});

  State<ChatScreen> createState() => _ChatScreenState();

}


// ----------------------------------

class _ChatScreenState extends State<ChatScreen>{

  final TextEditingController _messageController = TextEditingController();
  List<Map<String, dynamic>> _messages = [];

  void _sendMessage(){
    if (_messageController.text.trim().isNotEmpty){
      setState(() {
        _messages.add({
          'text': _messageController.text.trim(),
          'isSentByUser': true,
        });
        _messageController.clear();
      });


      Future.delayed(Duration(seconds: 3), () {
        setState(() {
          _messages.add({
            'text': "This is a simulated response",
            'isSentByUser': false,
          }); // Add bot response
        });
      });
    }
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
                maxHeight: 100
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