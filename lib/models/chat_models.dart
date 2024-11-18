// ./lib/data/chat_models.dart

const List<Map<String, dynamic>> chatModels = [
  {
    "name": "ChatGPT",
    "versions": [
      {"name": "GPT-4o-mini", "suffix": "GPT-4o-mini"},
      {"name": "GPT-3.5-turbo", "suffix": "GPT-3.5 Turbo"},
      {"name": "GPT-4o", "suffix": "GPT-4o"}
    ],
  },
  {
    "name": "Llama",
    "versions": [
      {"name": "Llama-v1", "suffix": "Llama Version 1"},
      {"name": "Llama-v2", "suffix": "Llama Version 2"},
    ],
  },
  {
    "name": "Gemini",
    "versions": [
      {"name": "Gemini-alpha", "suffix": "Gemini Alpha"},
      {"name": "Gemini-beta", "suffix": "Gemini Beta"},
    ],
  },
];