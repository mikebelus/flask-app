#!/bin/bash

# Find and kill the Gunicorn process
PID=$(ps aux | grep 'gunicorn app:app' | grep -v grep | awk '{print $2}')
if [ -z "$PID" ]; then
    echo "Gunicorn is not running!"
else
    kill -9 $PID
    echo "Gunicorn stopped!"
fi
