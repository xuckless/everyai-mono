Chat API Project

Overview

This is a simple Chat API built with FastAPI that responds to user messages. The API has a single endpoint /chat that accepts a message and returns an appropriate response based on the input.

Project Structure

.
├── main.py
├── models
│   ├── __init__.py
│   └── chat.py
├── routers
│   ├── __init__.py
│   └── chat.py
└── utils
    ├── __init__.py
    └── generate_response.py

	•	main.py: The entry point of the application. Initializes the FastAPI app and includes the router.
	•	models/: Contains Pydantic models for request and response data.
	•	chat.py: Defines ChatRequest and ChatResponse models.
	•	routers/: Contains API route definitions.
	•	chat.py: Defines the /chat endpoint.
	•	utils/: Contains utility functions.
	•	generate_response.py: Implements the logic to generate responses.

Setup Instructions

Prerequisites

	•	Python 3.6+ installed on your system.
	•	Git installed if cloning from a repository.

Clone the Repository

If you haven’t already, clone the repository:

git clone [repository_url]
cd [repository_name]

Replace [repository_url] with the actual URL and [repository_name] with the repository name.

Create and Activate a Virtual Environment

It’s recommended to use a virtual environment to manage dependencies.

Create the Virtual Environment

python3 -m venv .venv

Activate the Virtual Environment

	•	On macOS and Linux:

source .venv/bin/activate


	•	On Windows (Command Prompt):

.venv\Scripts\activate.bat


	•	On Windows (PowerShell):

.venv\Scripts\Activate.ps1



Install Dependencies

Install the required Python packages:

pip install fastapi uvicorn

Run the Application

Start the FastAPI application using Uvicorn:

uvicorn main:app --reload

	•	The app will be accessible at http://127.0.0.1:8000/. or http://10.0.2.2:8000
	•	The --reload flag restarts the server when code changes are detected (useful during development).

Test the API Endpoint

You can test the /chat endpoint using curl, HTTPie, or any API client.

Example with curl:

curl -X POST "http://127.0.0.1:8000/chat" -H "Content-Type: application/json" -d '{"message": "Hello"}'

Expected Response:

{
  "message": "Hi there! How can I assist you today?"
}

API Documentation

Interactive API docs are available:
	•	Swagger UI: http://127.0.0.1:8000/docs
	•	ReDoc: http://127.0.0.1:8000/redoc

Deactivate the Virtual Environment

When you’re done, deactivate the virtual environment:

deactivate

Notes

	•	Ensure that the __pycache__/ directory and the virtual environment directory (e.g., .venv/) are excluded from version control. Add them to your .gitignore file:

__pycache__/
.venv/


	•	If additional dependencies are added, include them in the pip install command or create a requirements.txt file.

How to migrate the database
first, you need to install alembic
pip install alembic

then run this command : alembic revision --autogenerate -m "Describe your changes"
then run this command : alembic upgrade head

Contact

If you have any questions or need assistance, feel free to reach out.

how to migrate the database:
run this command : alembic revision --autogenerate -m "Describe your changes"
then run this command : alembic upgrade head

Happy coding!
