#./utils/generate_response.py

def generate_response(message: str) -> str:
    if "hello" in message.lower():
        return "Hi there! How can I assist you today?"
    elif "bye" in message.lower():
        return "Goodbye! Have a great day!"
    elif "throughout heaven and earth, i alone am the honoured one" in message.lower():
        return "Nah I'd win!"
    else:
        return "I'm sorry, I didn't understand that. Can you rephrase?"