# Hither

Bring any window from your other Mac hither.

Hither streams individual app windows from one Mac to another. The app keeps running where it is; its window shows
up on this Mac as a real Mac window, with its own Dock icon, Cmd-Tab entry, Spaces, full screen and trackpad
swipes. Two Macs on one desk start to feel like one.

It's a developer project: you build it yourself with the Command Line Tools. No accounts, no cloud, only your
local network.

## What it does

- **Native windows.** Each remote app gets a small proxy app on this Mac (`Cursor · mini`), so it behaves like any
  other app: Dock, Cmd-Tab, Spaces, full screen, Mission Control.
- **Launch anything over there.** Spotlight finds every app on the other Mac (`Xcode · mini`), and the menu bar icon
  lists its open windows and recent apps.
- **Menus come along.** The remote app's menu bar is mirrored in the proxy.
- **New windows follow.** Cmd-N, File › New Window or opening a project over there opens here too.
- **Sound.** Each app's audio plays from its own proxy.
- **Fast.** Hardware H.264 or HEVC (4:2:2 for sharper colour), about 35–45 ms from keypress to picture on a home
  network. Hidden windows are paused and background windows are throttled.
- **Both directions.** Every Mac runs the same app: it shares its own windows and shows the other Mac's.
- **Whole desktop.** For the rare times you need it, the menu hands off to macOS Screen Sharing.

## Requirements

- Two Macs on the same local network, macOS 14 or later (built and used on Apple silicon, macOS 27).
- Swift from the Command Line Tools: `xcode-select --install`. Xcode isn't needed.

## Install

On each Mac, from a clone of this repo:

```bash
scripts/install.sh
```

Or install on the other Mac from this one over SSH: `scripts/install.sh other-mac.local`.

The script builds `Hither.app` into `~/Applications` and starts it. It signs with a self-signed identity it creates
in its own keychain (`~/Library/Keychains/hither-signing.keychain-db`), so macOS keeps Hither's permissions
across rebuilds.

On first launch, macOS asks for three permissions for **Hither**. Grant them on both Macs:

- **Screen & System Audio Recording**, to capture windows and their sound
- **Accessibility**, to type, click, resize and read menus
- **Local Network**, to find and reach the other Mac

## Pair

1. Click Hither's menu bar icon and choose **Pair with <other Mac>…**
2. Both Macs show a 6-digit code. Check they match, then click **Pair** on both.

Pairing is mutual, so both Macs can open each other's windows. Tick **Open at Login** on both, and you're done.

## Use

- Pick a window or app from the menu bar icon, or type an app's name in Spotlight (`Safari · mini`).
- Cmd-H and Cmd-M hide or minimise the window on this Mac. Ctrl-Cmd-F makes it full screen here. Every other key
  goes to the app.
- **Video Codec** in the menu switches every window between H.264, HEVC and HEVC 4:2:2.

## How it works

The host side captures each window with ScreenCaptureKit and encodes it with VideoToolbox on the media engine. The
client decodes it into a native window. Input goes back as keys, clicks, scrolls and gestures, and the host posts
them with CGEvent and Accessibility. Each remote app's proxy is an APFS clone of the Hither binary with its own
bundle name and icon, which is what gives it a Dock and Cmd-Tab identity. Proxies connect through a loopback relay in
the menu bar app, so only Hither itself needs Local Network access.

## Security

- Paired Macs can fully control each other. Only pair your own Macs.
- Pairing works like Bluetooth numeric comparison: an X25519 key exchange, where each side commits to its random
  value before seeing the other's, and a code derived from both that you compare on the two screens. A machine
  in the middle can't make both codes match. The key never crosses the network.
- After pairing, every connection is TLS with that pre-shared key, so unpaired Macs can't connect.
- Pairings live in `~/.hither/pairings.json` (readable only by you). **Unpair** is in the menu.

## Limitations

- The menu shows one other Mac at a time: the first one you paired.
- Same local network only. Macs find each other with Bonjour and connect via `<name>.local`.
- Keys are sent as key codes, so both Macs should use the same keyboard layout.
- The mouse pointer's shape (I-beam, resize arrows) isn't mirrored.
- A locked Mac can't be captured or typed into. Unlock it with Screen Sharing. To stop it locking again when you
  disconnect, run
  `sudo defaults write /Library/Preferences/com.apple.RemoteManagement RestoreMachineState -bool NO`.
- Audio is captured before the host's volume control. Mute the host if you only want sound on this Mac.
- There's no clipboard sync. Universal Clipboard already covers it.
- It isn't notarized, and it uses one private but widely used Accessibility call (`_AXUIElementGetWindow`) to match
  windows with their IDs.

## Development

```bash
swift build
.build/debug/hither --selftest            # pairs with itself over loopback
.build/debug/hither mini.local --list     # a paired Mac's windows
.build/debug/hither mini.local Safari     # stream one window without the menu bar app
```

Logs: `/tmp/hither.log` (menu bar app) and `/tmp/hither-host.log` (host). `HITHER_BITRATE` sets the video bitrate
(default 40 Mbps).

## Related

- [Transom](https://github.com/aydinmrnv/transom) streams Mac windows to a Windows PC.
- [Xpra](https://xpra.org) does per-window remoting on Linux.
- Parallels Coherence and VMware Unity do the same for virtual machines.

## License

MIT
