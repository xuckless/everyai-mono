// ./lib/data/chat_models.dart

import 'package:second_times_the_charm/models/api_service.dart';


ApiService apiService = ApiService();

final List<Map<String, dynamic>> chatModels = [
  {
    "name": "ChatGPT",
    "versions": [
      {"name": "GPT-4o-mini", "suffix": "GPT 4o mini"},
      {"name": "GPT-3.5-turbo", "suffix": "GPT 3.5 Turbo"},
      {"name": "GPT-4o", "suffix": "GPT 4o"}
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
      {"name": "gemini-1.5-flash-8b", "suffix": "Gemini 1.5 Flash 8B"},
      {"name": "gemini-1.5-flash", "suffix": "Gemini 1.5 Flash"},
      {"name": "gemini-1.5-pro", "suffix": "Gemini 1.5 Pro"},
      {"name": "gemini-1.0-pro", "suffix":"Gemini 1.0 Pro"},
    ],
    "function": (String message, String suffix) => apiService.g_chat(message, suffix),
  },
];