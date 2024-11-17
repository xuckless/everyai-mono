import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final String baseUrl;

  ApiService(this.baseUrl);

  // basic api module for making POST request
  Future<dynamic> post(String endpoint, Map<String, dynamic> body) async {

    final url = Uri.parse('$baseUrl/$endpoint');

    try {

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body)
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Request failed with status: ${response.statusCode}');
      }

    } catch (e){
      throw Exception('Failed to make POST request: $e');
    }
  }

  // POST request for Login page
  Future<dynamic> login(String email, String password) async {
    return await post(
      'login',
        {
          'email': email,
          'password': password
        }
    );
  }

  Future<dynamic> signUp(String name, String email, String password) async {
    return await post(
      'sign-up',
      {
        'name': name,
        'email': email,
        'password': password
      }
    );
  }


}