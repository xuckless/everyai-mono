// ./lib/services/chat_service.dart


import 'dart:convert';

import 'api_service.dart';

/// A service class responsible for handling all chat-related API interactions.
class ChatService {
  final ApiService _apiService;

  /// Initializes [ChatService] with an instance of [ApiService].
  ChatService(this._apiService);

  /// Sends a general chat message to the AI model.
  Future<dynamic> chat(String message) async {
    return await _apiService.post(
      'chat', // API endpoint for chat
      {'message': message}, // Request body
    );
  }

  /// Sends a chat message to a dynamically selected GPT model.
  ///
  /// - [message]: The user's message to be sent.
  /// - [suffix]: The identifier for the selected GPT model version.
  ///
  /// Returns the AI's response as a decoded JSON object.
  Future<dynamic> gptChat(String message, String suffix) async {
    return await _apiService.post(
      'chat/gpt', // API endpoint for GPT chat
      {'message': message, 'model': suffix}, // Request body
    );
  }

  Future<dynamic> geminiChat(String message, String suffix) async {
    return await _apiService.post(
      'chat/gemini', // API endpoint for Gemini chat
      {'message': message, 'model': suffix}, // Request body
    );
  }

  Future<dynamic> llamaChat(String message, String suffix) async {
    return await _apiService.post(
      'chat/llama', // API endpoint for LLaMA chat
      {'message': message, 'model': suffix}, // Request body
    );
  }

  Future<dynamic> xaiChat(String message, String suffix) async {
    return await _apiService.post(
      'chat/xai', // API endpoint for XAI chat
      {'message': message, 'model': suffix}, // Request body
    );
  }

  Future<dynamic> claudeChat(String message, String suffix) async {
    return await _apiService.post(
      'chat/claude', // API endpoint for Claude chat
      {'message': message, 'model': suffix}, // Request body
    );
  }

  Future<dynamic> stabilityImage(String message, String suffix) async {
    // Notice we call postRaw instead of post
    final response = await _apiService.postRaw(
      'chat/stability',
      {'message': message, 'model': suffix},
    );

    if (response.statusCode == 200) {
      // Check if it’s actually an image
      if (response.headers['content-type']?.contains('image/webp') ?? false) {
        // Return the binary
        return response.bodyBytes;
      } else {
        // If server returned JSON or error text
        final Map<String, dynamic> jsonBody = jsonDecode(response.body);
        print("Failed to generate image: ${jsonBody['error']}");
        return jsonBody['error'];
      }
    } else {
      print("Failed with status code: ${response.statusCode}");
      return "Failed to generate image";
    }
  }




}
