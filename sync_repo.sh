#!/bin/bash

# Check if Git is installed
if ! command -v git &> /dev/null
then
    echo "Error: Git is not installed."
    exit 1
fi

# Check if the current directory is a Git repository
if [ ! -d ".git" ]; then
    echo "Error: This directory is not a Git repository."
    exit 1
fi

# Fetch latest changes from the remote repository
echo "Fetching latest changes from remote..."
git pull --rebase

# Add all changes
echo "Adding all changes..."
git add .

# Commit with a default or user-provided message
commit_message="$1"
if [ -z "$commit_message" ]; then
    commit_message="Updated project: $(date)"
fi

echo "Committing changes with message: '$commit_message'"
git commit -m "$commit_message"

# Push changes to the remote repository
echo "Pushing changes to remote..."
git push

echo "Repository synced successfully!"
