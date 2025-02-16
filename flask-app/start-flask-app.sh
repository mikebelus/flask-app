#!/bin/bash

# Find and kill the Gunicorn process
PID=$(ps aux | grep 'gunicorn app:app' | grep -v grep | awk '{print $2}')
if [ -z "$PID" ]; then
    echo "Gunicorn is not running!"
else
    kill -9 $PID
    echo "Gunicorn stopped!"
fi

# Install dependencies from requirements.txt if needed
echo "Installing dependencies..."
pip install -r requirements.txt

# Start the Flask app using Gunicorn
echo "Starting Flask app with Gunicorn..."
nohup gunicorn app:app --bind 0.0.0.0:5050 &


# Give the app a few seconds to start
sleep 3

# Open Safari and navigate to the app
echo "Opening Safari..."
open -a "Safari" "http://127.0.0.1:5050"

echo "Flask app should now be running and open in Safari!"
