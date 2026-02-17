#!/bin/bash
set -e

IMAGE_NAME="ubuntu-desktop"
CONTAINER_NAME="ubuntu-desktop-app"
PERSISTENT_CONTAINER="ubuntu-desktop-persistent"

# --- Persistent mode (VNC) functions ---

ensure_image() {
    local build_flag="${1:-false}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if $build_flag; then
        echo "Building image '$IMAGE_NAME'..."
        podman build -t "$IMAGE_NAME" "$SCRIPT_DIR"
        return
    fi

    if ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
        echo "Image '$IMAGE_NAME' not found. Building..."
        podman build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    fi
}

cmd_start() {
    local BUILD=false
    local VNC_PORT=${VNC_PORT:-5901}
    local VNC_PASSWORD=${VNC_PASSWORD:-ubuntu}
    local VNC_GEOMETRY=${VNC_GEOMETRY:-1920x1080}
    local APP_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--build)       BUILD=true; shift ;;
            --vnc-port)       VNC_PORT="$2"; shift 2 ;;
            --vnc-password)   VNC_PASSWORD="$2"; shift 2 ;;
            --vnc-geometry)   VNC_GEOMETRY="$2"; shift 2 ;;
            -n|--name)        PERSISTENT_CONTAINER="$2"; shift 2 ;;
            *)                APP_ARGS+=("$1"); shift ;;
        esac
    done

    ensure_image "$BUILD"

    # Check if container already exists
    if podman container exists "$PERSISTENT_CONTAINER" 2>/dev/null; then
        local state
        state=$(podman inspect --format '{{.State.Status}}' "$PERSISTENT_CONTAINER" 2>/dev/null)
        if [ "$state" = "running" ]; then
            echo "Container '$PERSISTENT_CONTAINER' is already running."
            cmd_status
            return 0
        else
            echo "Restarting stopped container '$PERSISTENT_CONTAINER'..."
            podman start "$PERSISTENT_CONTAINER"
            sleep 2
            cmd_status
            return 0
        fi
    fi

    echo "Starting persistent desktop container..."

    local PODMAN_ARGS=(
        -d
        --name "$PERSISTENT_CONTAINER"
        -e VNC_PASSWORD="$VNC_PASSWORD"
        -e VNC_GEOMETRY="$VNC_GEOMETRY"
        -e DISPLAY_NUM=1
        -p "${VNC_PORT}:${VNC_PORT}"
        --security-opt label=type:container_runtime_t
        --userns=keep-id
    )

    # GPU access for hardware acceleration
    if [ -d /dev/dri ]; then
        PODMAN_ARGS+=(--device /dev/dri)
    fi

    # PulseAudio for sound support
    PULSE_SOCKET="${XDG_RUNTIME_DIR}/pulse/native"
    if [ -S "$PULSE_SOCKET" ]; then
        PODMAN_ARGS+=(-v "$PULSE_SOCKET:/tmp/pulse-native:rw" -e PULSE_SERVER=unix:/tmp/pulse-native)
    fi

    # Named volume to persist home directory across container recreations
    PODMAN_ARGS+=(-v ubuntu-desktop-home:/home/user)

    podman run "${PODMAN_ARGS[@]}" \
        --entrypoint /usr/local/bin/start-persistent.sh \
        "$IMAGE_NAME" "${APP_ARGS[@]}"

    sleep 2
    cmd_status
}

cmd_stop() {
    local REMOVE=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rm)   REMOVE=true; shift ;;
            -n|--name) PERSISTENT_CONTAINER="$2"; shift 2 ;;
            *)      shift ;;
        esac
    done

    if ! podman container exists "$PERSISTENT_CONTAINER" 2>/dev/null; then
        echo "Container '$PERSISTENT_CONTAINER' does not exist."
        return 1
    fi

    echo "Stopping container '$PERSISTENT_CONTAINER'..."
    podman stop "$PERSISTENT_CONTAINER"

    if $REMOVE; then
        echo "Removing container '$PERSISTENT_CONTAINER'..."
        podman rm "$PERSISTENT_CONTAINER"
    else
        echo "Container stopped (state preserved). Use 'start' to restart it."
        echo "Use 'stop --rm' to remove the container entirely."
    fi
}

cmd_run() {
    local APP_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) PERSISTENT_CONTAINER="$2"; shift 2 ;;
            *)         APP_ARGS+=("$1"); shift ;;
        esac
    done

    if [ ${#APP_ARGS[@]} -eq 0 ]; then
        echo "Usage: ./run-desktop-app.sh run <app> [args...]"
        echo "Example: ./run-desktop-app.sh run firefox"
        exit 1
    fi

    if ! podman container exists "$PERSISTENT_CONTAINER" 2>/dev/null; then
        echo "Error: Container '$PERSISTENT_CONTAINER' is not running."
        echo "Start it first: ./run-desktop-app.sh start"
        exit 1
    fi

    echo "Launching ${APP_ARGS[0]} in container..."
    podman exec -d \
        -e DISPLAY=:1 \
        "$PERSISTENT_CONTAINER" \
        /usr/local/bin/start-app.sh "${APP_ARGS[@]}"
    echo "Done. ${APP_ARGS[0]} is running in the persistent desktop."
}

cmd_shell() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) PERSISTENT_CONTAINER="$2"; shift 2 ;;
            *)         shift ;;
        esac
    done

    if ! podman container exists "$PERSISTENT_CONTAINER" 2>/dev/null; then
        echo "Error: Container '$PERSISTENT_CONTAINER' is not running."
        echo "Start it first: ./run-desktop-app.sh start"
        exit 1
    fi

    echo "Opening shell in persistent container..."
    podman exec -it -e DISPLAY=:1 "$PERSISTENT_CONTAINER" /bin/bash
}

cmd_status() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) PERSISTENT_CONTAINER="$2"; shift 2 ;;
            *)         shift ;;
        esac
    done

    if ! podman container exists "$PERSISTENT_CONTAINER" 2>/dev/null; then
        echo "Container '$PERSISTENT_CONTAINER' does not exist."
        echo "Start it with: ./run-desktop-app.sh start [app]"
        return 1
    fi

    local state
    state=$(podman inspect --format '{{.State.Status}}' "$PERSISTENT_CONTAINER" 2>/dev/null)

    echo "Container: $PERSISTENT_CONTAINER"
    echo "State:     $state"

    if [ "$state" = "running" ]; then
        local vnc_port
        vnc_port=$(podman inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "5901/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' "$PERSISTENT_CONTAINER" 2>/dev/null || echo "5901")
        [ -z "$vnc_port" ] && vnc_port="5901"

        echo ""
        echo "To connect from your local machine:"
        echo "  1) Set up SSH tunnel (run on local machine):"
        echo "       ssh -L ${vnc_port}:localhost:${vnc_port} <remote-host>"
        echo ""
        echo "  2) Connect VNC client to:"
        echo "       localhost:${vnc_port}"
        echo ""
        echo "  Password: ubuntu (or your custom VNC_PASSWORD)"
        echo ""
        echo "To launch more apps:  ./run-desktop-app.sh run <app>"
        echo "To open a shell:      ./run-desktop-app.sh shell"
        echo "To stop:              ./run-desktop-app.sh stop"
    fi
}

cmd_logs() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name) PERSISTENT_CONTAINER="$2"; shift 2 ;;
            *)         shift ;;
        esac
    done

    podman logs "$PERSISTENT_CONTAINER"
}

# --- Direct X11 mode (original behavior) ---

cmd_direct() {
    local BUILD=false
    local SHELL_MODE=false
    local APP_ARGS=()

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

    ensure_image "$BUILD"

    # Allow container to connect to the host X server
    if command -v xhost &>/dev/null; then
        xhost +local: > /dev/null 2>&1
    fi

    PODMAN_ARGS=(
        --rm
        --name "$CONTAINER_NAME"
        -e DISPLAY="$DISPLAY"
        -e LIBGL_ALWAYS_SOFTWARE=1
        --security-opt label=type:container_runtime_t
        --userns=keep-id
    )

    # Detect if DISPLAY is TCP-based (e.g. SSH X11 forwarding: "localhost:10.0")
    # vs a local Unix socket (e.g. ":0")
    if [[ "$DISPLAY" == localhost:* || "$DISPLAY" == *:*.* && "$DISPLAY" != :* ]]; then
        PODMAN_ARGS+=(--network=host)
    else
        PODMAN_ARGS+=(-v /tmp/.X11-unix:/tmp/.X11-unix:rw)
    fi

    # Share Xauthority for X11 authentication
    XAUTH_FILE="${XAUTHORITY:-$HOME/.Xauthority}"
    if [ -f "$XAUTH_FILE" ]; then
        PODMAN_ARGS+=(-v "$XAUTH_FILE:$HOME/.Xauthority:ro" -e XAUTHORITY="$HOME/.Xauthority")
    elif [ -n "$XAUTHORITY" ]; then
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
}

# --- Help ---

show_help() {
    cat <<'HELP'
Usage: ./run-desktop-app.sh <command> [options] [args...]

Persistent mode (VNC desktop — survives SSH disconnects):
  start [app]      Start background container with VNC desktop
  stop [--rm]      Stop container (--rm to remove it entirely)
  run <app>        Launch an app inside the running container
  shell            Open a bash shell in the running container
  status           Show connection info
  logs             Show container logs

  Persistent mode options:
    -b, --build           Rebuild the image first
    -n, --name NAME       Custom container name
    --vnc-port PORT       VNC port (default: 5901)
    --vnc-password PASS   VNC password (default: ubuntu)
    --vnc-geometry WxH    Screen resolution (default: 1920x1080)

Direct X11 mode (requires X11 forwarding, no persistence):
  <application>    Run an app with X11 forwarding (original behavior)
  -b, --build      Build image first
  -s, --shell      Open interactive shell
  -n, --name NAME  Custom container name

Examples:
  # Persistent mode (recommended for remote SSH):
  ./run-desktop-app.sh start firefox             # Start desktop with firefox
  ./run-desktop-app.sh run chromium-browser       # Launch another app
  ./run-desktop-app.sh shell                      # Open a shell
  ./run-desktop-app.sh stop                       # Stop (preserves state)
  ./run-desktop-app.sh start                      # Restart (resumes state)

  # Direct X11 mode (local or with X11 forwarding):
  ./run-desktop-app.sh firefox                    # Run firefox directly
  ./run-desktop-app.sh --build xeyes              # Build and run xeyes

Workflow for remote SSH:
  [remote]  ./run-desktop-app.sh start firefox
  [local]   ssh -L 5901:localhost:5901 user@remote-host
  [local]   vncviewer localhost:5901
  # Disconnect SSH any time — apps keep running
  # Reconnect SSH, re-tunnel, re-attach VNC — same state
HELP
}

# --- Main dispatch ---

case "${1:-}" in
    start)   shift; cmd_start "$@" ;;
    stop)    shift; cmd_stop "$@" ;;
    run)     shift; cmd_run "$@" ;;
    shell)   shift; cmd_shell "$@" ;;
    status)  shift; cmd_status "$@" ;;
    logs)    shift; cmd_logs "$@" ;;
    -h|--help)  show_help ;;
    "")         show_help ;;
    *)          cmd_direct "$@" ;;
esac
