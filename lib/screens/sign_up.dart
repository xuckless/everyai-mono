import 'package:flutter/material.dart';
import 'package:second_times_the_charm/screens/home.dart';


class SignUpPage extends StatefulWidget{
  final String title;

  const SignUpPage ({super.key, required this.title});

  State<SignUpPage> createState() => _SignUpState();
}


class _SignUpState extends State<SignUpPage>{


  final _formKey = GlobalKey<FormState>();

  void _validateLogin(){
    if (_formKey.currentState!.validate()){
      return;
    }
  }


  void _gotoHomePage(BuildContext context){
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => MyHomePage(title: 'hello'))
    );
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
            Text("Sign Up Today!",
            style: Theme.of(context).textTheme.headlineMedium,
            ),

            // Form Fields
            ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 380,
                maxHeight: 310,
                minWidth: 150,
                minHeight: 75
            ),
            child: Form (
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextFormField(
                    decoration: InputDecoration(
                      labelText: "Username",
                      border: UnderlineInputBorder(),
                    ),
                    validator: (value){
                      if (value == null || value.isEmpty){
                        return 'please enter your username';
                      } return null;
                    },
                  ),

                  TextFormField(
                    decoration: InputDecoration(
                      labelText: "Email",
                      border: UnderlineInputBorder(),
                    ),
                    validator: (value){
                      if (value == null || value.isEmpty){
                        return 'please enter your email';
                      } return null;
                    },
                  ),
                  TextFormField(
                    decoration: InputDecoration(
                      labelText: "Password",
                      border: UnderlineInputBorder(),
                    ),
                    validator: (value){
                      if (value == null || value.isEmpty){
                        return 'please enter your password';
                      } return null;
                    },
                    obscureText: true,
                  ),
                  TextFormField(
                    decoration: InputDecoration(
                      labelText: "Confirm Password",
                      border: UnderlineInputBorder(),
                    ),
                    validator: (value){
                      if (value == null || value.isEmpty){
                        return 'please confirm password';
                      } return null;
                    },
                    obscureText: true,
                  ),
                ],
              ),
            ),
          ),

            // sign up button
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
                      onPressed: _validateLogin,
                      child: Text("Sign Up"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                      )
                  ),
                ),
              ],
            ),
          ),


            Text("Or sign up through:",
              style: Theme.of(context).textTheme.bodyMedium,
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