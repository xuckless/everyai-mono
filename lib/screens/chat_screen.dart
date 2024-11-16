import 'package:flutter/material.dart';
import 'package:second_times_the_charm/screens/home.dart';

// ------------------------------

class ChatScreen extends StatefulWidget{
  final String title;

  const ChatScreen({super.key, required this.title});

  State<ChatScreen> createState() => _ChatScreenState();

}


// ----------------------------------

class _ChatScreenState extends State<ChatScreen>{





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
              child: Container(
                height: MediaQuery.of(context).size.height - 220,
                width: MediaQuery.of(context).size.width,
                color: Colors.lightBlue,
              ),
            ),

            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width,
                maxHeight: 100
              ),
              child: Container(
                color: Colors.lightGreen,
                child: TextFormField(
                  decoration: InputDecoration(
                    labelText: "Chat",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4.0)
                    ),
                  ),
                ),
              ),
            )
          ],
        ),
      ),




    );
  }
}