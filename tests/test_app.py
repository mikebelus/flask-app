import pytest
from app import app

def test_homepage():
    """Test if the homepage loads correctly."""
    client = app.test_client()
    response = client.get('/')
    assert response.status_code == 200
    assert response.data == b'Hello, World! Running locally!'

def test_404_page():
    """Test if a non-existent page returns a 404."""
    client = app.test_client()
    response = client.get('/not-a-route')
    assert response.status_code == 404

def test_script_injection():
    """Test if the app handles script injection attempts safely."""
    client = app.test_client()
    response = client.get('/<script>alert("test")</script>')
    assert response.status_code == 404

def test_gunicorn_compatibility():
    """Ensure the app can be loaded as a WSGI app."""
    from app import app as wsgi_app  # Simulate Gunicorn loading
    assert wsgi_app is not None

