#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: start-app.sh <application> [args...]"
    echo ""
    echo "Examples:"
    echo "  start-app.sh xeyes"
    echo "  start-app.sh xclock"
    echo "  start-app.sh firefox"
    echo ""
    echo "To install an application first:"
    echo "  sudo apt-get update && sudo apt-get install -y <package>"
    echo ""
    echo "Starting a shell instead..."
    exec /bin/bash
fi

if [ -z "$DISPLAY" ]; then
    echo "Error: DISPLAY is not set."
    echo "Make sure you run the container with the correct X11 options."
    echo "See run-desktop-app.sh for reference."
    exit 1
fi

APP="$1"
shift

if ! command -v "$APP" &>/dev/null; then
    echo "Application '$APP' not found."
    echo "Attempting to install it..."
    sudo apt-get update -qq && sudo apt-get install -y -qq "$APP" 2>/dev/null
    if ! command -v "$APP" &>/dev/null; then
        echo "Error: Could not find or install '$APP'."
        echo "Try installing the correct package manually:"
        echo "  sudo apt-get update && sudo apt-get install -y <package-name>"
        exit 1
    fi
fi

echo "Starting $APP ..."
exec "$APP" "$@"
