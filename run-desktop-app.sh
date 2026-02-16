#!/bin/bash
set -e

IMAGE_NAME="ubuntu-desktop"
CONTAINER_NAME="ubuntu-desktop-app"

show_help() {
    echo "Usage: ./run-desktop-app.sh [options] [application] [args...]"
    echo ""
    echo "Run a desktop application inside a Podman container."
    echo ""
    echo "Options:"
    echo "  -b, --build       Build (or rebuild) the container image before running"
    echo "  -s, --shell       Open an interactive shell instead of running an app"
    echo "  -n, --name NAME   Set a custom container name (default: $CONTAINER_NAME)"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./run-desktop-app.sh --build xeyes          # Build image, then run xeyes"
    echo "  ./run-desktop-app.sh xclock                  # Run xclock"
    echo "  ./run-desktop-app.sh --shell                 # Open a bash shell"
    echo "  ./run-desktop-app.sh firefox                 # Run firefox (auto-installs)"
    echo "  ./run-desktop-app.sh --name myapp gedit      # Run gedit with custom name"
}

BUILD=false
SHELL_MODE=false
APP_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--build)
            BUILD=true
            shift
            ;;
        -s|--shell)
            SHELL_MODE=true
            shift
            ;;
        -n|--name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            APP_ARGS+=("$1")
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if $BUILD; then
    echo "Building image '$IMAGE_NAME'..."
    podman build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

if ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    echo "Image '$IMAGE_NAME' not found. Building..."
    podman build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# Allow container to connect to the host X server
if command -v xhost &>/dev/null; then
    xhost +local: > /dev/null 2>&1
fi

PODMAN_ARGS=(
    --rm
    --name "$CONTAINER_NAME"
    -e DISPLAY="$DISPLAY"
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw
    --security-opt label=type:container_runtime_t
    --userns=keep-id
)

# Share Xauthority if available
if [ -n "$XAUTHORITY" ]; then
    PODMAN_ARGS+=(-v "$XAUTHORITY:$XAUTHORITY:ro" -e XAUTHORITY="$XAUTHORITY")
fi

# PulseAudio for sound support
PULSE_SOCKET="${XDG_RUNTIME_DIR}/pulse/native"
if [ -S "$PULSE_SOCKET" ]; then
    PODMAN_ARGS+=(-v "$PULSE_SOCKET:/tmp/pulse-native:rw" -e PULSE_SERVER=unix:/tmp/pulse-native)
fi

# GPU access for hardware acceleration
if [ -d /dev/dri ]; then
    PODMAN_ARGS+=(--device /dev/dri)
fi

if $SHELL_MODE; then
    echo "Starting interactive shell in container..."
    podman run -it "${PODMAN_ARGS[@]}" "$IMAGE_NAME" /bin/bash
elif [ ${#APP_ARGS[@]} -gt 0 ]; then
    echo "Starting ${APP_ARGS[0]} in container..."
    podman run -it "${PODMAN_ARGS[@]}" "$IMAGE_NAME" "${APP_ARGS[@]}"
else
    show_help
    exit 1
fi
