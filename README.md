# vol_ubuntu

Containerized Ubuntu desktop environment with GUI app support. Run graphical Linux applications in an isolated Podman container, accessible locally via X11 forwarding or remotely via VNC.

## Features

- **Persistent VNC desktop** — survives SSH disconnects; reconnect any time to the same session
- **Direct X11 mode** — launch individual GUI apps with native X11 forwarding
- **Remote deployment** — deploy the full desktop to a remote server over SSH with one command
- **Pre-installed browsers** — Firefox (from Mozilla PPA) and Google Chrome
- **Custom .deb packages** — drop `.deb` files into `external_app/` and they're installed at build time
- **Hardware acceleration** — GPU passthrough via `/dev/dri` when available
- **Audio support** — PulseAudio passthrough for sound in containerized apps
- **Rootless containers** — runs with Podman (no daemon, no root required)

## Prerequisites

- [Podman](https://podman.io/) (rootless)
- A VNC client (e.g. [TigerVNC Viewer](https://tigervnc.org/), [RealVNC](https://www.realvnc.com/)) for persistent mode
- `rsync` and `ssh` for remote deployment
- X11 server on the host for direct mode (optional)

## Quick Start

### Persistent Desktop (VNC)

Start a persistent desktop that runs in the background:

```bash
./run-desktop-app.sh start
```

Connect with a VNC client:

```bash
vncviewer localhost:5901
# Default password: ubuntu
```

Launch additional apps inside the running desktop:

```bash
./run-desktop-app.sh run firefox
./run-desktop-app.sh run google-chrome-stable
```

Stop the desktop (state is preserved):

```bash
./run-desktop-app.sh stop
```

### Direct X11 Mode

Run a single GUI app with X11 forwarding (no persistence):

```bash
./run-desktop-app.sh direct firefox
./run-desktop-app.sh direct xeyes
```

Open an interactive shell in direct mode:

```bash
./run-desktop-app.sh direct --shell
```

### Remote Deployment

Deploy the desktop to a remote server:

```bash
./run-desktop-app.sh deploy user@myserver
```

Then tunnel VNC back to your local machine:

```bash
ssh -L 5901:localhost:5901 user@myserver
vncviewer localhost:5901
```

Manage the remote container from your local machine:

```bash
./run-desktop-app.sh status -H user@myserver
./run-desktop-app.sh run -H user@myserver firefox
./run-desktop-app.sh stop -H user@myserver
```

Redeploy (stop, re-sync, rebuild, restart):

```bash
./run-desktop-app.sh redeploy user@myserver
```

## Usage

```
./run-desktop-app.sh <command> [options] [args...]
```

### Commands

| Command | Description |
|---------|-------------|
| `start [app]` | Start persistent VNC desktop (optionally launch an app) |
| `stop [--rm]` | Stop the container (`--rm` to remove it entirely) |
| `run <app>` | Launch an app inside the running container |
| `shell` | Open a bash shell in the running container |
| `status` | Show container state and connection info |
| `logs` | Show container logs |
| `deploy <user@host>` | Sync files, build image, and start on a remote host |
| `redeploy <user@host>` | Stop, re-sync, rebuild, and restart on a remote host |
| `direct <app>` | Run a single GUI app with X11 forwarding (no persistence) |

### Options

| Option | Description |
|--------|-------------|
| `-b, --build` | Force rebuild the container image |
| `-n, --name NAME` | Custom container name |
| `-s, --shell` | Open an interactive shell (direct mode only) |
| `-H, --host HOST` | Execute the command on a remote host via SSH |
| `--vnc-port PORT` | VNC port (default: `5901`) |
| `--vnc-password PASS` | VNC password (default: `ubuntu`) |
| `--vnc-geometry WxH` | Screen resolution (default: `1920x1080`) |
| `--remote-dir DIR` | Remote working directory (default: `~/vol_ubuntu`) |
| `-i, --identity KEY` | SSH identity file |
| `-p, --port PORT` | SSH port |
| `-o, --ssh-opt OPT` | Extra SSH option |

## Custom Packages

To include additional `.deb` packages in the image, place them in the `external_app/` directory before building:

```bash
cp my-app.deb external_app/
./run-desktop-app.sh start -b
```

## Project Structure

```
.
├── Dockerfile              # Ubuntu container with X11/VNC, browsers, fonts
├── run-desktop-app.sh      # Main CLI — start, stop, deploy, etc.
├── start-app.sh            # Entrypoint for launching a single GUI app
├── start-persistent.sh     # Entrypoint for the persistent VNC desktop
└── external_app/           # Drop .deb files here for auto-install at build
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VNC_PORT` | `5901` | VNC server port |
| `VNC_PASSWORD` | `ubuntu` | VNC connection password |
| `VNC_GEOMETRY` | `1920x1080` | VNC display resolution |

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
