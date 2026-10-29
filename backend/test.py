import pytest
import httpx

import utils.generate_response

BASE_URL = "http://127.0.0.1:8000"

@pytest.fixture(scope="session")
def client():
    """Fixture to initialize an HTTPX client."""
    with httpx.Client(base_url=BASE_URL) as client:
        yield client

def test_ping(client):
    """Test the ping endpoint."""
    response = client.get("/ping")
    assert response.status_code == 200
    assert response.json() == {"message": "Pong!"}

def test_signup(client):
    """Test the sign-up endpoint."""
    response = client.post("/signup", json={"email": "testuser@example.com", "password": "securepassword"})
    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"

def test_login(client):
    """Test the login endpoint."""
    response = client.post("/login", json={"email": "testuser@example.com", "password": "securepassword"})
    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    return data["access_token"]

def test_protected_route(client):
    """Test the protected route."""
    # First login to get the access token
    login_response = client.post("/login", json={"email": "testuser@example.com", "password": "securepassword"})
    assert login_response.status_code == 200
    access_token = login_response.json()["access_token"]

    # Use the access token to access the protected route
    headers = {"Authorization": f"Bearer {access_token}"}
    response = client.get("/protected", headers=headers)
    assert response.status_code == 200
    assert "message" in response.json()

def test_chat(client):
    """Test the chat endpoint."""
    response = client.post("/chat", json={"message": "Hello"})
    assert response.status_code == 200
    data = response.json()
    assert "message" in data
    assert len(data["message"]) > 0


def test_gpt_chat(client):
    """Test the GPT chat endpoint."""
    # Define a test input message
    test_message = "What is the capital of France?"

    # Send a request to the chat endpoint
    response = client.post("/chat", json={"message": test_message})

    # Ensure the response status code is correct
    assert response.status_code == 200

    # Parse the response JSON
    data = response.json()

    # Verify the response contains the expected fields
    assert "message" in data

    # Example: Verify GPT's response matches expectations (adjust based on actual response logic)
    expected_response = "The capital of France is Paris."
    assert data["message"] == expected_response
