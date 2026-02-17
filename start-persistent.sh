#!/bin/bash
set -e

DISPLAY_NUM=${DISPLAY_NUM:-1}
VNC_PORT=$((5900 + DISPLAY_NUM))
VNC_GEOMETRY=${VNC_GEOMETRY:-1920x1080}
export DISPLAY=:${DISPLAY_NUM}

# Set up VNC password
mkdir -p ~/.vnc
echo "${VNC_PASSWORD:-ubuntu}" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

cleanup() {
    echo "Shutting down persistent desktop..."
    kill $(jobs -p) 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT

# Start VNC server (Xtigervnc = X server + VNC in one process)
Xtigervnc :"${DISPLAY_NUM}" \
    -geometry "${VNC_GEOMETRY}" \
    -depth 24 \
    -rfbport "${VNC_PORT}" \
    -rfbauth ~/.vnc/passwd \
    -AlwaysShared \
    -desktop "Ubuntu Container" \
    -pn &
VNC_PID=$!

# Wait for X server to become ready
for _ in $(seq 1 20); do
    if xdpyinfo -display :"${DISPLAY_NUM}" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! xdpyinfo -display :"${DISPLAY_NUM}" >/dev/null 2>&1; then
    echo "ERROR: VNC/X server failed to start"
    exit 1
fi

# Start D-Bus session (needed by GTK/Qt apps)
if command -v dbus-launch &>/dev/null; then
    eval "$(dbus-launch --sh-syntax)"
fi

# Start lightweight window manager
openbox &

# Start a terminal so the desktop isn't empty
xterm -geometry 100x30+50+50 &

# Launch initial application if specified
if [ $# -gt 0 ]; then
    APP="$1"
    shift
    if ! command -v "$APP" &>/dev/null; then
        echo "Application '$APP' not found. Installing..."
        sudo apt-get update -qq && sudo apt-get install -y -qq "$APP" 2>/dev/null || true
    fi
    if command -v "$APP" &>/dev/null; then
        echo "Starting $APP..."
        "$APP" "$@" &
    else
        echo "WARNING: Could not find or install '$APP'"
    fi
fi

echo "========================================="
echo " Persistent desktop ready"
echo " VNC port: ${VNC_PORT}"
echo " Password: ${VNC_PASSWORD:-ubuntu}"
echo " Resolution: ${VNC_GEOMETRY}"
echo ""
echo " Connect from your local machine:"
echo "   1) ssh -L ${VNC_PORT}:localhost:${VNC_PORT} <remote-host>"
echo "   2) vncviewer localhost:${VNC_PORT}"
echo "========================================="

# Keep container alive as long as VNC server runs
while kill -0 "$VNC_PID" 2>/dev/null; do
    wait "$VNC_PID" 2>/dev/null || true
done
