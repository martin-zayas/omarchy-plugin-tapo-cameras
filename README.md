# TAPO Cameras — Omarchy Plugin

View TP-Link TAPO security cameras via RTSP in a floating picture-in-picture window on Omarchy 4 (Arch Linux + Hyprland + Quickshell).

- **PiP overlay** — draggable floating window always on top while you work
- **Bar panel** — add, edit, and select cameras; play/stop; PiP size presets
- **RTSP** — works with TAPO Camera Account credentials
- **Auto-reconnect** — retries every 5s after stream errors
- **Pause on fullscreen** — pauses when a fullscreen window covers the PiP monitor
- **`tapo-cameras` CLI** — scripting and keybinds

## Requirements

- [Omarchy 4](https://omarchy.com)+ with **omarchy-shell**
- Hyprland
- Packages: `qt6-multimedia`, `gst-plugins-good`, `gst-libav`

## Install

### Recommended (dependencies + plugin + CLI)

```bash
git clone https://github.com/martin-zayas/martin-zayas-tapo-cameras.git
cd martin-zayas-tapo-cameras
./install.sh
```

`install.sh` checks which packages are missing and runs `sudo pacman -S --needed` only for those.

### Plugin only (no dependency install)

```bash
omarchy plugin add https://github.com/martin-zayas/martin-zayas-tapo-cameras.git --enable
```

Install RTSP packages manually if needed:

```bash
sudo pacman -S --needed qt6-multimedia gst-plugins-good gst-libav
```

## TAPO camera setup

1. Open the **Tapo** app on your phone
2. Go to **Camera Settings → Advanced Settings → Camera Account**
3. Create a username and password for RTSP (separate from your TP-Link ID)
4. Note your camera's local IP address

### RTSP URLs

| Stream | URL | Use |
|--------|-----|-----|
| High quality | `rtsp://user:pass@IP:554/stream1` | Full resolution |
| Low quality | `rtsp://user:pass@IP:554/stream2` | Recommended for PiP |

Test with ffplay before adding to the plugin:

```bash
ffplay -rtsp_transport tcp rtsp://USER:PASS@192.168.1.50:554/stream2
```

## Usage

1. Click the **camera icon** in the bar (right section by default)
2. Fill in **Add camera**: name, host/IP, port `554`, path `/stream2`, Camera Account username/password
3. Click **Add**, then click the camera in the list to start streaming
4. **Drag** the PiP window by its title bar to reposition it

### PiP size

Use **S / M / L** buttons in the panel (320×180, 480×270, 640×360).

### CLI

```bash
tapo-cameras status
tapo-cameras play entrada
tapo-cameras toggle
tapo-cameras stop
```

Optional keybind in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + C", "TAPO cameras toggle", "tapo-cameras toggle")
```

## Configuration files

| Path | Purpose |
|------|---------|
| `~/.local/state/martin-zayas-tapo-cameras/state.json` | Cameras, PiP position, settings |
| `~/.local/state/martin-zayas-tapo-cameras/credentials.json` | Passwords (`chmod 600`) |

Passwords are stored in plain text with restrictive file permissions (v1). Do not commit these files.

Optional seed in `~/.config/omarchy/shell.json` under `plugins[]` (hosts only, no passwords):

```json
{
  "id": "martin-zayas-tapo-cameras",
  "cameras": [
    {
      "id": "entrada",
      "name": "Entrada",
      "host": "192.168.1.50",
      "port": 554,
      "path": "/stream2",
      "username": "tapo_user"
    }
  ]
}
```

## Development

```bash
ln -s /path/to/martin-zayas-tapo-cameras ~/.config/omarchy/plugins/martin-zayas-tapo-cameras
omarchy plugin validate .
omarchy restart shell
```

## Update / remove

```bash
omarchy plugin update martin-zayas-tapo-cameras
omarchy plugin remove martin-zayas-tapo-cameras
```

## License

MIT — see [LICENSE](LICENSE).
