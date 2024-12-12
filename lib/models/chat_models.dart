import 'package:second_times_the_charm/models/api/api_service.dart';
import 'api/chat_service.dart';

/// An instance of [ApiService] to handle API interactions.
final ApiService apiService = ApiService();

/// An instance of [ChatService] initialized with the [ApiService].
final ChatService chatService = ChatService(apiService);

/// A list of available chat models, each with its own versions, associated
/// chat functions, and corresponding image assets.
///
/// Each chat model is represented as a `Map<String, dynamic>` containing:
/// - **name**: The display name of the chat model.
/// - **versions**: A list of available versions for the model, each with its own name and suffix.
/// - **function**: A callback function that sends messages using the selected model.
/// - **picture**: The asset path to the model's representative image.
final List<Map<String, dynamic>> chatModels = [
  {
    "name": "ChatGPT",
    "versions": [
      {"name": "GPT-4o-mini", "suffix": "GPT 4o mini"},
      {"name": "GPT-3.5-turbo", "suffix": "GPT 3.5 Turbo"},
      {"name": "GPT-4o", "suffix": "GPT 4o"}
    ],
    "function": (String message, String suffix) => chatService.gptChat(message, suffix),
    "picture": "assets/models/chatgpt.webp",
  },
  {
    "name": "Llama",
    "versions": [
      {"name": "Llama-v1", "suffix": "Llama Version 1"},
      {"name": "Llama-v2", "suffix": "Llama Version 2"},
    ],
    "function": (String message, String suffix) => chatService.llamaChat(message, suffix),
    "picture": "assets/models/Llama.jpeg",
  },
  {
    "name": "Gemini",
    "versions": [
      {"name": "gemini-1.5-flash-8b", "suffix": "1.5 Flash 8B"},
      {"name": "gemini-1.5-flash", "suffix": "1.5 Flash"},
      {"name": "gemini-1.5-pro", "suffix": "1.5 Pro"},
      {"name": "gemini-1.0-pro", "suffix": "1.0 Pro"},
    ],
    "function": (String message, String suffix) => chatService.geminiChat(message, suffix),
    "picture": "assets/models/gemini.png",
  },
  {
    "name": "Claude",
    "versions": [
      {"name": "Claude-3-Haiku", "suffix": "Claude 3 Haiku"},
      {"name": "Claude-3-Sonnet", "suffix": "Claude 3 Sonnet"},
      {"name": "Claude-3-Opus", "suffix": "Claude 3 Opus"},
    ],
    "function": (String message, String suffix) => chatService.gptChat(message, suffix),
    "picture": "assets/models/claude.webp",
  },
  {
    "name": "X-Ai",
    "versions": [
      {"name": "grok-beta", "suffix": "Grok Beta"},
    ],
    "function": (String message, String suffix) => chatService.xaiChat(message, suffix),
    "picture": "assets/models/xai.webp",
  },
];

Map<String, bool> chatModelAddedStatus = {
  for (var model in chatModels)
    model['name']: model['name'] == 'ChatGPT' ? true : false
};

void toggleModelStatus(String modelName) {
  if (chatModelAddedStatus.containsKey(modelName)) {
    chatModelAddedStatus[modelName] = !chatModelAddedStatus[modelName]!;
  }
}
