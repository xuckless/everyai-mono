// ./lib/data/chat_models.dart

import 'package:second_times_the_charm/models/api_service.dart';


ApiService apiService = ApiService();

final List<Map<String, dynamic>> chatModels = [
  {
    "name": "ChatGPT",
    "versions": [
      {"name": "GPT-4o-mini", "suffix": "GPT-4o-mini"},
      {"name": "GPT-3.5-turbo", "suffix": "GPT-3.5 Turbo"},
      {"name": "GPT-4o", "suffix": "GPT-4o"}
    ],
    "function": (String message, String suffix) => apiService.d_chat(message, suffix),
  },
  {
    "name": "Llama",
    "versions": [
      {"name": "Llama-v1", "suffix": "Llama Version 1"},
      {"name": "Llama-v2", "suffix": "Llama Version 2"},
    ],
    "function": (String message, String suffix) => apiService.f_chat(message, suffix),
  },
  {
    "name": "Gemini",
    "versions": [
      {"name": "Gemini-alpha", "suffix": "Gemini Alpha"},
      {"name": "Gemini-beta", "suffix": "Gemini Beta"},
    ],
    "function": (String message, String suffix) => apiService.g_chat(message, suffix),
  },
];