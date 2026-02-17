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
        -p "127.0.0.1:${VNC_PORT}:${VNC_PORT}"
        --security-opt label=type:container_runtime_t
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

    # Bind-mount local home directory into the container
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mkdir -p "$SCRIPT_DIR/home"
    PODMAN_ARGS+=(-v "$SCRIPT_DIR/home:/home:rw")

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
        echo ""
        echo "From a remote machine, add -H <host> to any command:"
        echo "  ./run-desktop-app.sh status -H user@this-host"
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

# --- Remote deployment via SSH ---

cmd_deploy() {
    local REMOTE_HOST=""
    local REMOTE_DIR="~/vol_ubuntu"
    local BUILD=false
    local START=true
    local VNC_PORT=${VNC_PORT:-5901}
    local VNC_PASSWORD=${VNC_PASSWORD:-ubuntu}
    local VNC_GEOMETRY=${VNC_GEOMETRY:-1920x1080}
    local SSH_OPTS=()
    local APP_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--build)           BUILD=true; shift ;;
            --no-start)           START=false; shift ;;
            --vnc-port)           VNC_PORT="$2"; shift 2 ;;
            --vnc-password)       VNC_PASSWORD="$2"; shift 2 ;;
            --vnc-geometry)       VNC_GEOMETRY="$2"; shift 2 ;;
            --remote-dir)         REMOTE_DIR="$2"; shift 2 ;;
            -n|--name)            PERSISTENT_CONTAINER="$2"; shift 2 ;;
            -o|--ssh-opt)         SSH_OPTS+=(-o "$2"); shift 2 ;;
            -i|--identity)        SSH_OPTS+=(-i "$2"); shift 2 ;;
            -p|--port)            SSH_OPTS+=(-p "$2"); shift 2 ;;
            -*)                   echo "Unknown option: $1"; exit 1 ;;
            *)
                if [ -z "$REMOTE_HOST" ]; then
                    REMOTE_HOST="$1"
                else
                    APP_ARGS+=("$1")
                fi
                shift
                ;;
        esac
    done

    if [ -z "$REMOTE_HOST" ]; then
        echo "Usage: ./run-desktop-app.sh deploy <user@host> [options] [app]"
        echo ""
        echo "Options:"
        echo "  -b, --build             Force rebuild the image on remote"
        echo "  --no-start              Only sync files and build; don't start"
        echo "  --remote-dir DIR        Remote directory (default: ~/vol_ubuntu)"
        echo "  --vnc-port PORT         VNC port (default: 5901)"
        echo "  --vnc-password PASS     VNC password (default: ubuntu)"
        echo "  --vnc-geometry WxH      Resolution (default: 1920x1080)"
        echo "  -n, --name NAME         Container name"
        echo "  -i, --identity KEY      SSH identity file"
        echo "  -p, --port PORT         SSH port"
        echo "  -o, --ssh-opt OPT       Extra SSH option"
        echo ""
        echo "Examples:"
        echo "  ./run-desktop-app.sh deploy user@myserver"
        echo "  ./run-desktop-app.sh deploy user@myserver -b firefox"
        echo "  ./run-desktop-app.sh deploy user@myserver -i ~/.ssh/id_rsa --vnc-port 5902"
        exit 1
    fi

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    echo "=== Deploying to $REMOTE_HOST ==="

    # Step 1: Sync project files to remote host
    echo ""
    echo "[1/3] Syncing project files to ${REMOTE_HOST}:${REMOTE_DIR} ..."

    local RSYNC_SSH_CMD="ssh"
    if [ ${#SSH_OPTS[@]} -gt 0 ]; then
        RSYNC_SSH_CMD="ssh ${SSH_OPTS[*]}"
    fi

    # Create remote directory
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

    rsync -az --delete \
        --exclude '.git' \
        --exclude '.gitignore' \
        -e "$RSYNC_SSH_CMD" \
        "$SCRIPT_DIR/" "${REMOTE_HOST}:${REMOTE_DIR}/"

    echo "  Files synced."

    # Step 2: Build image on remote host
    echo ""
    echo "[2/3] Building container image on remote host..."

    local REMOTE_BUILD_CMD
    if $BUILD; then
        REMOTE_BUILD_CMD="cd $REMOTE_DIR && podman build -t $IMAGE_NAME ."
    else
        REMOTE_BUILD_CMD="cd $REMOTE_DIR && podman image exists $IMAGE_NAME 2>/dev/null || podman build -t $IMAGE_NAME ."
    fi

    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$REMOTE_BUILD_CMD"
    echo "  Image ready."

    # Step 3: Start the container on remote host
    if ! $START; then
        echo ""
        echo "Files synced and image built. Skipping container start (--no-start)."
        echo "SSH into the remote host and run:"
        echo "  cd $REMOTE_DIR && ./run-desktop-app.sh start ${APP_ARGS[*]}"
        return 0
    fi

    echo ""
    echo "[3/3] Starting container on remote host..."

    local START_CMD="cd $REMOTE_DIR && ./run-desktop-app.sh start"
    START_CMD+=" --vnc-port $VNC_PORT"
    START_CMD+=" --vnc-password $VNC_PASSWORD"
    START_CMD+=" --vnc-geometry $VNC_GEOMETRY"
    START_CMD+=" -n $PERSISTENT_CONTAINER"
    if [ ${#APP_ARGS[@]} -gt 0 ]; then
        START_CMD+=" ${APP_ARGS[*]}"
    fi

    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$START_CMD"

    local _H_OPTS=""
    if [ ${#SSH_OPTS[@]} -gt 0 ]; then
        for _opt in "${SSH_OPTS[@]}"; do
            _H_OPTS+=" $_opt"
        done
    fi

    echo ""
    echo "========================================="
    echo " Deployed to $REMOTE_HOST"
    echo "========================================="
    echo ""
    echo " To connect, set up an SSH tunnel and VNC:"
    echo ""
    echo "   ssh ${SSH_OPTS[*]} -L ${VNC_PORT}:localhost:${VNC_PORT} $REMOTE_HOST"
    echo "   vncviewer localhost:${VNC_PORT}"
    echo ""
    echo " VNC password: $VNC_PASSWORD"
    echo ""
    echo " To manage the remote container:"
    echo "   ./run-desktop-app.sh status -H $REMOTE_HOST${_H_OPTS}"
    echo "   ./run-desktop-app.sh run -H $REMOTE_HOST${_H_OPTS} <app>"
    echo "   ./run-desktop-app.sh stop -H $REMOTE_HOST${_H_OPTS}"
    echo "   ./run-desktop-app.sh shell -H $REMOTE_HOST${_H_OPTS}"
    echo "   ./run-desktop-app.sh logs -H $REMOTE_HOST${_H_OPTS}"
    echo "========================================="
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
    )

    # Detect if DISPLAY is TCP-based (e.g. SSH X11 forwarding: "localhost:10.0")
    # vs a local Unix socket (e.g. ":0")
    if [[ "$DISPLAY" == localhost:* || "$DISPLAY" == *:*.* && "$DISPLAY" != :* ]]; then
        PODMAN_ARGS+=(--network=host)
    else
        PODMAN_ARGS+=(-v /tmp/.X11-unix:/tmp/.X11-unix:rw)
    fi

    # Create a container-readable copy of Xauthority with a wildcard cookie.
    # Without --userns=keep-id the container UID differs from the host UID,
    # so we cannot simply bind-mount the original file (mode 600, wrong owner).
    XAUTH_FILE="${XAUTHORITY:-$HOME/.Xauthority}"
    XAUTH_TMP=""
    if [ -f "$XAUTH_FILE" ] && command -v xauth &>/dev/null; then
        XAUTH_TMP=$(mktemp "/tmp/.xauth-container-XXXXXX")
        xauth nlist "$DISPLAY" 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_TMP" nmerge - 2>/dev/null
        chmod 644 "$XAUTH_TMP"
        PODMAN_ARGS+=(-v "$XAUTH_TMP:/tmp/.xauth:ro" -e XAUTHORITY=/tmp/.xauth)
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

    run_and_cleanup() {
        podman run "$@"
        local rc=$?
        [ -n "$XAUTH_TMP" ] && rm -f "$XAUTH_TMP"
        return $rc
    }

    if $SHELL_MODE; then
        echo "Starting interactive shell in container..."
        run_and_cleanup -it "${PODMAN_ARGS[@]}" "$IMAGE_NAME" /bin/bash
    elif [ ${#APP_ARGS[@]} -gt 0 ]; then
        echo "Starting ${APP_ARGS[0]} in container..."
        run_and_cleanup -it "${PODMAN_ARGS[@]}" "$IMAGE_NAME" "${APP_ARGS[@]}"
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

Remote execution (run any command on a remote host via SSH):
  -H, --host HOST   Run the command on a remote host instead of locally
                     (requires prior 'deploy' to sync files to the remote)

  Remote options (used with -H):
    --remote-dir DIR      Remote directory (default: ~/vol_ubuntu)
    -i, --identity KEY    SSH identity file
    -p, --port PORT       SSH port
    -o, --ssh-opt OPT     Extra SSH option (e.g. StrictHostKeyChecking=no)

Remote deployment (deploy and start on a remote host via SSH):
  deploy <user@host> [app]   Sync files, build image, and start on remote

  Deploy options:
    -b, --build           Force rebuild the image on remote
    --no-start            Only sync and build; don't start container
    --remote-dir DIR      Remote directory (default: ~/vol_ubuntu)
    --vnc-port PORT       VNC port (default: 5901)
    --vnc-password PASS   VNC password (default: ubuntu)
    --vnc-geometry WxH    Screen resolution (default: 1920x1080)
    -n, --name NAME       Custom container name
    -i, --identity KEY    SSH identity file
    -p, --port PORT       SSH port
    -o, --ssh-opt OPT     Extra SSH option (e.g. StrictHostKeyChecking=no)

Direct X11 mode (requires X11 forwarding, no persistence):
  <application>    Run an app with X11 forwarding (original behavior)
  -b, --build      Build image first
  -s, --shell      Open interactive shell
  -n, --name NAME  Custom container name

Examples:
  # Deploy to remote (first time — syncs files, builds image, starts):
  ./run-desktop-app.sh deploy user@myserver firefox
  ./run-desktop-app.sh deploy user@myserver -b --vnc-port 5902
  ./run-desktop-app.sh deploy user@myserver -i ~/.ssh/id_rsa

  # Manage remote container from your local machine (after deploy):
  ./run-desktop-app.sh start -H user@myserver           # Start
  ./run-desktop-app.sh stop -H user@myserver             # Stop
  ./run-desktop-app.sh stop --rm -H user@myserver        # Stop and remove
  ./run-desktop-app.sh run -H user@myserver firefox      # Launch app
  ./run-desktop-app.sh shell -H user@myserver            # Open remote shell
  ./run-desktop-app.sh status -H user@myserver           # Check status
  ./run-desktop-app.sh logs -H user@myserver             # View logs

  # Remote with SSH options:
  ./run-desktop-app.sh status -H user@myserver -i ~/.ssh/id_rsa -p 2222

  # Connect VNC:
  ssh -L 5901:localhost:5901 user@myserver
  vncviewer localhost:5901

  # Persistent mode (local):
  ./run-desktop-app.sh start firefox             # Start desktop with firefox
  ./run-desktop-app.sh run chromium-browser       # Launch another app
  ./run-desktop-app.sh shell                      # Open a shell
  ./run-desktop-app.sh stop                       # Stop (preserves state)
  ./run-desktop-app.sh start                      # Restart (resumes state)

  # Direct X11 mode (local or with X11 forwarding):
  ./run-desktop-app.sh firefox                    # Run firefox directly
  ./run-desktop-app.sh --build xeyes              # Build and run xeyes

Workflow for remote SSH:
  [local]   ./run-desktop-app.sh deploy user@remote-host firefox
  [local]   ssh -L 5901:localhost:5901 user@remote-host
  [local]   vncviewer localhost:5901
  # Disconnect SSH any time — apps keep running
  # Reconnect SSH, re-tunnel, re-attach VNC — same state
  # Manage remotely:
  [local]   ./run-desktop-app.sh status -H user@remote-host
  [local]   ./run-desktop-app.sh run -H user@remote-host chromium-browser
  [local]   ./run-desktop-app.sh stop -H user@remote-host
HELP
}

# --- Remote execution via -H/--host ---

_has_remote=false
for _a in "$@"; do
    [[ "$_a" == "-H" || "$_a" == "--host" ]] && _has_remote=true && break
done

if $_has_remote; then
    _REMOTE_HOST=""
    _REMOTE_DIR="~/vol_ubuntu"
    _REMOTE_SSH_OPTS=()
    _CMD_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -H|--host)       _REMOTE_HOST="$2"; shift 2 ;;
            --remote-dir)    _REMOTE_DIR="$2"; shift 2 ;;
            -i|--identity)   _REMOTE_SSH_OPTS+=(-i "$2"); shift 2 ;;
            -p|--port)       _REMOTE_SSH_OPTS+=(-p "$2"); shift 2 ;;
            -o|--ssh-opt)    _REMOTE_SSH_OPTS+=(-o "$2"); shift 2 ;;
            *)               _CMD_ARGS+=("$1"); shift ;;
        esac
    done

    if [ -z "$_REMOTE_HOST" ]; then
        echo "Error: -H/--host requires a host argument"
        exit 1
    fi

    _REMOTE_CMD="cd ${_REMOTE_DIR} && ./run-desktop-app.sh"
    for _arg in "${_CMD_ARGS[@]}"; do
        _REMOTE_CMD+=" $(printf '%q' "$_arg")"
    done

    case "${_CMD_ARGS[0]:-}" in
        shell)
            exec ssh "${_REMOTE_SSH_OPTS[@]}" -t "$_REMOTE_HOST" "$_REMOTE_CMD"
            ;;
        *)
            exec ssh "${_REMOTE_SSH_OPTS[@]}" "$_REMOTE_HOST" "$_REMOTE_CMD"
            ;;
    esac
fi

# --- Main dispatch ---

case "${1:-}" in
    start)   shift; cmd_start "$@" ;;
    stop)    shift; cmd_stop "$@" ;;
    run)     shift; cmd_run "$@" ;;
    shell)   shift; cmd_shell "$@" ;;
    status)  shift; cmd_status "$@" ;;
    logs)    shift; cmd_logs "$@" ;;
    deploy)  shift; cmd_deploy "$@" ;;
    -h|--help)  show_help ;;
    "")         show_help ;;
    *)          cmd_direct "$@" ;;
esac
