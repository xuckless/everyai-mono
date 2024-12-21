# ./utils/generate_response.py
import requests
import json

import config
from openai import OpenAI
import requests


import google.generativeai as genai
import anthropic
import os

from config import CLAUDE_API_KEY
from config import STABILITY_API_KEY

genai.configure(api_key=config.GEMINI_API_KEY)

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
        return assistant_response
    except Exception as e:
        # Handle and return error
        return f"An error occurred while generating: {e}"


def gemini_response(message: str, model: str) -> str:
    try:
        model = genai.GenerativeModel(model)
        response = model.generate_content(message)
        return response.text
    except Exception as ex:
        return f'An error occurred while generating: {ex}'



xai_message_history = [
            {
                "role": "system",
                "content": "You are Grok, a chatbot AI assistant"
            },
]



def xai_response(message: str, model: str) -> str:
    url = "https://api.x.ai/v1/chat/completions"
    xai_message_history.append({"role": "user", "content": message})

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {config.GROK_API_KEY}"
    }

    payload = {
        "messages": xai_message_history,
        "model": model,
        "stream": False,
        "temperature": 0
    }

    response = requests.post(url, headers=headers, json=payload)
    response.raise_for_status()

    response_body = response.json()
    print(response_body)

    # Try to extract the content. If it fails, return an empty string.
    try:
        content = response_body["choices"][0]["message"]["content"]
        xai_message_history.append({"role": "assistant", "content": content})
        return str(content)
    except (KeyError, IndexError, TypeError):
        # If the structure isn't what we expect or doesn't have the fields,
        # just return an empty string.
        return "xai is under maintainance"

def claude_response(message: str, model: str, max_tokens: int) -> str:
    try:
        # Initialize the Anthropic client
        client = anthropic.Anthropic(api_key=CLAUDE_API_KEY)  # Replace with your actual API key

        # Use the Messages API
        response = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            messages=[
                {"role": "user", "content": message}
            ]
        )

        # Extract the content text
        if response.content and isinstance(response.content, list):
            # Join text from all TextBlock elements if there are multiple
            return ''.join(block.text for block in response.content if hasattr(block, 'text'))
        else:
            return "No valid content found in the response."
    except Exception as ex:
        print(f"Error occurred: {ex}")
        return f"An error occurred while generating: {ex}"

# def stability_response():
#     import requests
#
#     response = requests.post(
#         f"https://api.stability.ai/v2beta/stable-image/generate/ultra",
#         headers={
#             "authorization": f"Bearer {STABILITY_API_KEY}",
#             "accept": "image/*"
#         },
#         files={"none": ''},
#         data={
#             "prompt": "Lighthouse on a cliff overlooking the ocean",
#             "output_format": "webp",
#         },
#     )
#
#     if response.status_code == 200:
#         with open("./lighthouse.webp", 'wb') as file:
#             file.write(response.content)
#     else:
#         raise Exception(str(response.json()))