def generate_response(message: str) -> str:
    if "hello" in message.lower():
        return "Hi there! How can I assist you today?"
    elif "bye" in message.lower():
        return "Goodbye! Have a great day!"
    else:
        return "I'm sorry, I didn't understand that. Can you rephrase?"