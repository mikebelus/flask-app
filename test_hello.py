# test_hello.py
import pytest
from hello import app

@pytest.fixture
def client():
    with app.test_client() as client:
        yield client

def test_hello_world(client):
    """Test the Hello World page."""
    response = client.get('/')
    assert response.status_code == 200
    assert response.data.decode() == "Hello, World!"

