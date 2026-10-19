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
- **Whole desktop.** Desktop, at the top of each Mac's section, streams its whole screen the same smooth way:
  menu bar, Dock and every window. You can unlock a locked Mac from there too. Its toolbar picks how:
  **Adaptive** has the other Mac's dark screen take the resolution closest to this window (Retina on a Retina
  screen), so it shows about 1:1; resize the window and it re-fits when you let go. **Native** leaves its resolution
  alone: zoom out, 1:1 and in (⌃⌥⌘−, ⌃⌥⌘0, ⌃⌥⌘=) or fit (⌃⌥⌘9), and when it's bigger than the window, the picture
  follows the pointer: where it is across the window is where it is across that screen.
- **Sharp text.** While its screen is dark, the other Mac switches to its roomiest Retina mode as long as you're
  viewing its windows on a Retina screen, so they're captured at 2x (a Native Desktop leaves it as it is).
- **Keep Screen Dark.** While you use a Mac from here, its own monitors show black, so whoever sits near it
  doesn't see what you're doing. Two minutes after you close its last window, it locks and the monitors come
  back showing the lock screen. **Lock** locks it right away.
- **Clipboard, when you ask.** **Send Clipboard** puts what you copied here on the other Mac's clipboard;
  **Get Clipboard** brings theirs back. Nothing moves until you choose it. Text, rich text and images, up to 8 MB.
  Files and folders copied in Finder go too, at any size: they land in Downloads and on the clipboard, ready to
  paste anywhere. While they move, the menu bar shows **↓51%** (↑ when sending); the menu shows the file, speed,
  time left and **Cancel**, and a notification says when it's done (click it to show the files).
- **Screen Sharing.** The menu still hands off to macOS Screen Sharing when you want it.

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

Pairing is mutual, so both Macs can open each other's windows. Tick **Settings › Open at Login** on both, and you're done.

A Mac on another network (over [Tailscale](https://tailscale.com)) doesn't show up nearby: choose **Settings › Pair with Mac at
Address…** and type its Tailscale name or IP. You'll need to click Pair on that Mac's screen too, so have Screen
Sharing open. Pair as many Macs as you like; each gets its own section in the menu: its Desktop, its open windows, Recent,
and a submenu named after it with Clipboard, Keep Screen Dark, Lock, Video Codec, Screen Share and Unpair.

## Use

- Pick a window or app from the menu bar icon, or type an app's name in Spotlight (`Safari · mini`).
- Cmd-H and Cmd-M hide or minimise the window on this Mac. Ctrl-Cmd-F makes it full screen here. Every other key
  goes to the app.
- Ctrl-Option-Cmd-C in a remote window sends your clipboard there; Ctrl-Option-Cmd-V gets theirs. Both are also at
  the bottom of the window's Edit menu, and in the Mac's submenu of the menu bar icon.
- **Video Codec** in the Mac's submenu switches every window between H.264, HEVC and HEVC 4:2:2.

## iPhone

`iOS/Hither.xcodeproj` is a viewer for iPhone and iPad. It shares nothing; it opens your Mac's windows one at a
time, full screen. The Mac sizes the window to fit the phone and puts it back when you leave.

- Build it with Xcode (sign in under Settings › Accounts and pick your team) and run it on your phone.
- **Pair:** the Mac shows up under Nearby Macs. Tap it, check both screens show the same code, and click Pair on
  the Mac too. Paired iPhones get their own **Unpair** item under **Settings** in the Mac's menu.
- **Touch:** tap to click (tap again quickly for a double click), two-finger tap to right-click, drag to scroll,
  touch and hold then drag to select or move things.
- **Typing:** the keyboard button types into the window. The bar above the keyboard has esc, tab, arrows and
  ⌃ ⌥ ⌘ ⇧, which apply to the next key or tap (⌘ then S saves).
- **Window size:** Actual Size shows Mac points at iPhone size. More Space fits more in with smaller text.

## How it works

The host side captures each window with ScreenCaptureKit and encodes it with VideoToolbox on the media engine. The
client decodes it into a native window. Input goes back as keys, clicks, scrolls and gestures, and the host posts
them with CGEvent and Accessibility. Each remote app's proxy is an APFS clone of the Hither binary with its own
bundle name and icon, which is what gives it a Dock and Cmd-Tab identity. Proxies connect through a loopback relay in
the menu bar app, so only Hither itself needs Local Network access.

Control, input, menus, audio and the clipboard go over TCP 7420. A file copy gets a TCP 7420 connection of its own,
so a big one never waits behind a window's traffic or holds up its input. It runs at full speed, so windows may lag a
little while it does; Cancel is in the menu. Video goes over UDP 7421 when both ends support
it, so a lost packet costs one frame's repair instead of holding up every frame behind it. Each frame is split into
datagrams that fit Tailscale's MTU. The viewer asks again for any missing pieces, and when a frame can't be saved
in time it waits for a keyframe instead of showing a broken picture. The datagrams are sealed with ChaChaPoly
using a key that each TLS connection exports, so the pairing is still the only thing that lets a Mac in. If no
datagrams get through, or they stop for 3 s, video carries on over TCP. The iPhone app uses TCP.

Over UDP a Mac viewer uses H.264 with long-term references (LTR): the viewer confirms each frame it shows, and every
frame is built only on confirmed ones. So a lost frame spoils only itself; the next one decodes, with no repair to
wait for and no keyframe. (VideoToolbox's HEVC encoder doesn't support this, so over UDP the codec setting doesn't
apply; it does for TCP and the iPhone.) Keys, clicks and scrolls also go over UDP, three copies each, and the host
applies each once and in order, whether its UDP or TCP copy arrives first.

## Security

- Paired Macs can fully control each other. Only pair your own Macs.
- Pairing works like Bluetooth numeric comparison: an X25519 key exchange, where each side commits to its random
  value before seeing the other's, and a code derived from both that you compare on the two screens. A machine
  in the middle can't make both codes match. The key never crosses the network.
- After pairing, every connection is TLS with that pre-shared key, so unpaired Macs can't connect.
- Pairings live in `~/.hither/pairings.json` (readable only by you). **Unpair** is in each Mac's submenu.

## Limitations

- Macs find each other with Bonjour on the same network. Elsewhere, pair by address over Tailscale; Hither then
  tries `<name>.local`, the Tailscale name, and the address it paired from, in turn.
- If the other Mac's firewall is on, allow incoming connections for Hither there (TCP 7420 and UDP 7421).
- Keys are sent as key codes, so both Macs should use the same keyboard layout.
- The mouse pointer's shape (I-beam, resize arrows) isn't mirrored.
- A locked Mac shows its lock screen in Desktop; type your password there. A window stream can't show it.
  macOS locks a Mac when a Screen Sharing session ends; to stop that, run
  `sudo defaults write /Library/Preferences/com.apple.RemoteManagement RestoreMachineState -bool NO`.
- Keep Screen Dark blacks out the picture, not the Mac: its own keyboard and mouse still work while you use it.
  It only covers the session on the monitors; another user can't log in there at the same time.
- Audio is captured before the host's volume control. Mute the host if you only want sound on this Mac.
- The clipboard only moves on Send or Get Clipboard, never by itself. Copied files skip symlinks and special files,
  and a copy that's cancelled or cut off leaves nothing behind.
  macOS may ask once whether Hither can read the clipboard; allow it in Privacy & Security › Paste from Other Apps.
- It isn't notarized, and it uses one private but widely used Accessibility call (`_AXUIElementGetWindow`) to match
  windows with their IDs.

## Troubleshooting

**The picture freezes, but typing still reaches the other Mac.** Usually the network is losing packets between
the two Macs. Over UDP, mild loss shows as a brief pause while missing pieces are sent again. Heavy loss (10% or
more) still stalls the picture, and over TCP any loss does, because TCP stops and waits for every lost packet.
Keystrokes are tiny, so they still get through. The host log (`/tmp/hither-host.log` on the other Mac) shows a
`stats` line every 5 s: `udp` or `tcp`, `0 fps` while the screen is changing, `delivery` times of several seconds,
and with UDP, the codec (`h264+ltr` when frames are built on confirmed ones), how many frames were `lost`, how many
datagrams were `resent`, and how much input arrived first over UDP or TCP (`input udp/tcp`).

To see how video copes with loss, set `HITHER_DROP=0.05` to drop 5% of video datagrams at random: on the host for
outgoing ones, or on the dev viewer (`HITHER_DROP=0.05 .build/release/hither <host> @desktop`) for incoming ones.

Over Tailscale between two networks, the cause can be a single bad route. Providers pick a route partly by the
connection's port numbers, so after a restart one Mac's connection can land on a lossy path while another Mac
reaching the same place is fine. To check, ping both of your Macs from the far one at the same time:

```sh
ping -c 60 -i 0.2 -q <this Mac's Tailscale IP> & ping -c 60 -i 0.2 -q <another Mac's Tailscale IP> & wait
```

If one shows real loss (10% or more) and the other doesn't, restart Tailscale on the far Mac. It gets new ports,
and with them a different route. With Tailscale from Homebrew that's `sudo brew services restart tailscale`; with
the Tailscale app, quit it and open it again. Nothing in Hither needs changing, and it reconnects by itself.

**A Mac in someone else's tailnet doesn't connect.** Its name may not resolve here. Pair by address (its Tailscale
IP) and Hither keeps that address as a fallback.

## Development

```bash
swift build
swift run hither-tests                   # window lifecycle and transport regression checks (no Xcode needed)
.build/debug/hither --selftest            # pairs with itself over loopback
.build/debug/hither mini.local --list     # a paired Mac's windows
.build/debug/hither mini.local Safari     # stream one window without the menu bar app
# Optional: leave an app window open on the paired host; checks missing IDs directly and through Hither's relay.
swift run hither-tests --remote mini.local com.apple.finder
```

Logs: `/tmp/hither.log` (menu bar app) and `/tmp/hither-host.log` (host). `HITHER_BITRATE` sets the video bitrate
(default 40 Mbps).

## Related

- [Transom](https://github.com/aydinmrnv/transom) streams Mac windows to a Windows PC.
- [Xpra](https://xpra.org) does per-window remoting on Linux.
- Parallels Coherence and VMware Unity do the same for virtual machines.

## License

MIT
