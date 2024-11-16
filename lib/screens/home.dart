import 'package:flutter/material.dart';
import 'package:second_times_the_charm/screens/chat_screen.dart';
import 'package:second_times_the_charm/screens/sign_up.dart';

// -----------------------------

class MyHomePage extends StatefulWidget{
  final String title; //field

  const MyHomePage({super.key, required this.title});

  State<MyHomePage> createState() => _MyHomeState();
}

// -------------------------------

class _MyHomeState extends State<MyHomePage> {
  String _loginValue = "";

  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();

  void _setLoginValue() {
    setState(() {
      _loginValue = "Login key is pressed";
    });
  }

   bool _validateLogin(){
    if (_formKey.currentState!.validate()){
      _setLoginValue();
      return true;
    }
    _resetLoginValue();
    return false;
  }

  void _resetLoginValue() {
    setState(() {
      _loginValue = "";
    });
  }

  void _navigateToSignUpPage(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => SignUpPage(title: 'Welcome Home')),
    );
  }

  void _navigateToChatPage(BuildContext context){
    if (_validateLogin()){
      Navigator.push(context,
        MaterialPageRoute(builder: (context) => ChatScreen(title: "ChatScreen")),
      );
    }
    return;
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text("Welcome to EveryAI beta.",
              style: Theme.of(context).textTheme.headlineSmall,),

            // Text
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: 50,
                maxWidth: 150,
              ),
              child: Column (
                children: [
                  Text("$_loginValue")
                ],
              ),
            ),

            // Text Fields
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 380,
                maxHeight: 200,
                minWidth: 150,
                minHeight: 75
            ),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextFormField(
                      decoration: InputDecoration(
                        labelText: "Email",
                        border: UnderlineInputBorder(),
                      ),
                      validator: (value){
                        if (value == null || value.isEmpty){
                          return 'Please enter your email';
                        } return null;
                      },
                      controller: _emailController,
                    ),
                    TextFormField(
                      decoration: InputDecoration(
                        labelText: "Password",
                        border: UnderlineInputBorder(),
                      ),
                      validator: (value){
                        if (value == null || value.isEmpty){
                          return 'Please enter your password';
                        } return null;
                      },
                      obscureText: true,
                    ),
                  ],
                ),
              )
            ),

            // Login/Signup buttons
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: 50,
                maxWidth: 250,
              ),

              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Container(decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.transparent,
                      width:10.0
                    ),
                    borderRadius: BorderRadius.circular(0),
                  ),
                    child: ElevatedButton(
                      onPressed: () {
                        _navigateToChatPage(context);
                        },
                      child: Text("Login"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                      )
                    ),
                  ), //Container

                  Container(decoration: BoxDecoration(
                    border: Border.all(
                        color: Colors.transparent,
                        width:10.0
                    ),
                    borderRadius: BorderRadius.circular(0),
                  ),
                    child: ElevatedButton(
                      onPressed: () {
                        _navigateToSignUpPage(context);
                      },
                      child: Text("Sign Up"),
                    ),
                  ), //Container

                ],
              ),
            ),

            // forgot password button
            FloatingActionButton.extended(
              onPressed: () {
                print("Forgot Password Pressed");
              },
              label: Text(
                "Forgot Password",
                style: TextStyle(
                  fontSize: 14,
                  decoration: TextDecoration.underline,
                ),
              ),
              backgroundColor: Colors.transparent, // Transparent background
              elevation: 0, // Remove shadow
              highlightElevation: 0, // Remove shadow when pressed
            ),

            // Other sign in options
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: 380,
                  maxHeight: 120,
                  minWidth: 150,
                  minHeight: 75
              ),
              child: Center(
                child: Row (
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[

                    Container(decoration: BoxDecoration(
                      border: Border.all(
                          color: Colors.transparent,
                          width:10.0
                      ),
                      borderRadius: BorderRadius.circular(0),
                    ),
                      child: FloatingActionButton.large(
                        onPressed: null,
                        child: Icon(Icons.grade),
                      ),
                    ),

                    Container(decoration: BoxDecoration(
                      border: Border.all(
                          color: Colors.transparent,
                          width:10.0
                      ),
                      borderRadius: BorderRadius.circular(0),
                    ),
                      child: FloatingActionButton.large(
                        onPressed: null,
                        child: Icon(Icons.grade),
                      ),
                    ),

                    Container(decoration: BoxDecoration(
                      border: Border.all(
                          color: Colors.transparent,
                          width:10.0
                      ),
                      borderRadius: BorderRadius.circular(0),
                    ),
                      child: FloatingActionButton.large(
                        onPressed: null,
                        child: Icon(Icons.grade),
                      ),
                    ),

                  ],
                ),
              )
            ),

          ],
        )
      )
    );
  }
}
