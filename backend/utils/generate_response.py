# ./utils/generate_response.py
from openai.types.chat import ChatCompletionMessage
import config
from openai import OpenAI

# Initialize the OpenAI client
client = OpenAI()
client.api_key = config.OPENAI_API_KEY

conversation_history = [
    {"role": "system", "content": "You are a helpful assistant."}
]

conversation_history_two = conversation_history


def generate_response(message: str) -> str:
    """
    Generates a response from GPT-4o-mini based on the provided message,
    maintaining the context of the conversation.

    Args:
        message (str): The user's input message.

    Returns:
        str: The generated response from the model or an error message.
    """
    try:
        # Append the user's message to the conversation history
        conversation_history_two.append({"role": "user", "content": message})

        # Create a chat completion with the full conversation history
        completion = client.chat.completions.create(
            model="gpt-4o-mini",  # Replace with the appropriate model if different
            messages=conversation_history_two
        )

        # Extract the assistant's response
        assistant_response = completion.choices[0].message.content

        # Append the assistant's response to the conversation history
        conversation_history_two.append({"role": "assistant", "content": assistant_response})

        # Return the assistant's response
        return assistant_response
    except Exception as e:
        # Handle and return error
        return f"An error occurred while generating: {e}"


def specific_response(message: str, model: str) -> str:
    try:
        conversation_history.append({"role": "user", "content": message})
        # Create a chat completion
        completion = client.chat.completions.create(
            model=model,  # Replace with appropriate model if different
            messages=conversation_history
        )
        assistant_response = completion.choices[0].message.content
        conversation_history.append({"role": "assistant", "content": assistant_response})
        # Return the model's response
        return assistant_response.encode('utf-8').decode('utf-8')
    except Exception as e:
        # Handle and return error
        return f"An error occurred while generating: {e}"