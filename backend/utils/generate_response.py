# ./utils/generate_response.py
from openai.types.chat import ChatCompletionMessage
import config
from openai import OpenAI

# Initialize the OpenAI client
client = OpenAI()
client.api_key = config.OPENAI_API_KEY


def generate_response(message: str) -> str:
    """
    Generates a response from GPT-4o-mini based on the provided message.

    Args:
        message (str): The input message for the GPT model.

    Returns:
        str: The generated response from the model or an error message.
    """
    try:
        # Create a chat completion
        completion = client.chat.completions.create(
            model="gpt-4o-mini",  # Replace with appropriate model if different
            messages=[
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": message}
            ]
        )
        # Return the model's response
        return completion.choices[0].message.content
    except Exception as e:
        # Handle and return error
        return f"An error occurred while generating: {e}"


def specific_response(message: str, model: str) -> str:
    try:
        # Create a chat completion
        completion = client.chat.completions.create(
            model=model,  # Replace with appropriate model if different
            messages=[
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": message}
            ]
        )
        # Return the model's response
        return completion.choices[0].message.content
    except Exception as e:
        # Handle and return error
        return f"An error occurred while generating: {e}"