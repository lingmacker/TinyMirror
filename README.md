<div align="center">

# MirrorDeck

**Put your iPhone screen on your Mac over Wi-Fi.**

[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#requirements)
[![Release](https://img.shields.io/github/v/release/egarl004/mirrordeck)](https://github.com/egarl004/mirrordeck/releases/latest)

</div>

MirrorDeck turns your Mac into a wireless screen-mirroring target. It appears in
your iPhone's Control Center under **Screen Mirroring**, exactly like an Apple TV
— pick it, and your phone shows up in a native macOS window on your desktop.
Nothing to install on the phone.

MirrorDeck is display-only: mouse and keyboard input stays on your Mac.

---

## Installing

Download the latest `.dmg` from **[Releases](https://github.com/egarl004/mirrordeck/releases/latest)**,
open it, and drag MirrorDeck to Applications.

The app is signed with a Developer ID and notarized by Apple, so it opens
without a Gatekeeper warning.

MirrorDeck lives in the **menu bar**, without a Dock icon. The mirror window
opens automatically when a phone connects; **Show Mirror Window** opens the
connection guide at any time. On first launch macOS will ask for **local network
permission**; mirroring cannot work without it.

Then on your iPhone: **Control Center → Screen Mirroring → "‹your Mac› (MirrorDeck)"**.

### Requirements

| | |
|---|---|
| **macOS** | 26 (Tahoe) or later — Apple silicon or Intel |
| **iPhone** | Any iPhone on the same Wi-Fi network |
| **For mirroring** | Nothing else. No phone-side install. |

## Mirror window

The picture sits inside a slim, 5-point graphite frame with softly rounded
corners and the native window shadow. Full screen removes the frame for an
edge-to-edge view. There are no floating controls. The native close, minimize,
and full-screen buttons are hidden by default: hover near their
top-left position to reveal them, and leave that area to hide them. Hovering the
rest of the picture does not reveal the buttons. VoiceOver keeps
the buttons available. **Escape** exits full screen.

Choose **Show Mirror Window** in the menu bar even before connecting to see
connection instructions. The waiting screen stays until the first video frame
is actually ready, rather than showing an empty black picture. Closing only
hides the window. Stop mirroring from your iPhone's Control Center to disconnect.
While idle, the window uses a 9:18 phone-shaped canvas. Connecting follows the
device's actual aspect ratio; disconnecting restores the default phone shape.

Drag the title bar or picture to move the window. Resizing preserves the video
aspect ratio, and rotating the phone fits the new orientation to your display
without cropping the picture.

Choose **Keep Window on Top** in the menu bar to float the mirror above other
applications. It is on by default, and your choice is remembered across launches.

## Languages

The app supports **English** and **Simplified Chinese**, following the macOS
system/app language setting. Other languages fall back to English. Menu items,
connection and error messages, accessibility descriptions, and the local network
permission prompt are localized. Device names and the MirrorDeck name are unchanged.
Restart the app after changing its language in System Settings.

## Known limitations

Worth reading before you install — some of these are permanent.

- **No audio.** Video only; audio frames are currently discarded.
- **Display only.** Touch, keyboard, and pointer forwarding are not supported.
- **No Mac App Store.** The App Store accepts neither the AirPlay
  implementation nor GPL-licensed code. Direct download is the only route, the
  same one Reflector and AirServer take.

## Troubleshooting

**The menu bar icon doesn't appear.** On a Mac with a notch, macOS can place a
new status item *behind the notch*, where it renders as nothing and cannot be
clicked — even with free space beside it. MirrorDeck seeds a menu bar position
on first launch to avoid that. If the icon is still missing, your menu bar is
genuinely full: quit a menu bar app or two. You can ⌘-drag the icon anywhere
afterwards and the position is remembered.

Run with `MIRRORDECK_DEBUG=1` to have the app report exactly where it placed the
icon and whether that is behind the notch.

**Mirroring doesn't appear in Control Center.** Check both devices are on the
same network, and that MirrorDeck has local network permission (System Settings
→ Privacy & Security → Local Network).

## Building from source

Requires Xcode, plus Homebrew `openssl@3`, `libplist`, `cmake`, `pkg-config`.

```sh
./scripts/bootstrap.sh   # fetch UxPlay at a pinned commit
./native/build.sh        # build the AirPlay core -> libMirrorCore.dylib
swift build
swift run MirrorDeck
```

### Regression checks

Window layout and reconnect checks run without a phone or the native AirPlay library:

```sh
mkdir -p .build/module-cache
swiftc -target "$(uname -m)-apple-macos26.0" -module-cache-path .build/module-cache Sources/MirrorDeck/{Localization,MirrorVideoView,MirrorWindowController}.swift scripts/TestResources.swift scripts/check-window.swift -o .build/check-window
.build/check-window              # add --snapshots for light/dark layouts with labeled synthetic content
swiftc -module-cache-path .build/module-cache Sources/MirrorDeck/VideoPipeline.swift scripts/check-video.swift -o .build/check-video
.build/check-video
swiftc -target "$(uname -m)-apple-macos26.0" -module-cache-path .build/module-cache Sources/MirrorDeck/Localization.swift scripts/TestResources.swift scripts/check-localizations.swift -o .build/check-localizations
.build/check-localizations -AppleLanguages '(en)'
.build/check-localizations -AppleLanguages '(zh-Hans)'
.build/check-localizations -AppleLanguages '(fr)'  # English fallback
.build/check-window -AppleLanguages '(zh-Hans)'   # Chinese layout and window behavior
```

### Distribution

To produce a distributable app and disk image:

```sh
./scripts/package.sh                 # -> dist/MirrorDeck.app + dist/MirrorDeck-<ver>.dmg
NOTARIZE=1 ./scripts/package.sh      # also notarize and staple both
```

`package.sh` signs with a *Developer ID Application* certificate when one exists
and falls back to ad-hoc signing otherwise — ad-hoc builds run locally but
Gatekeeper blocks them elsewhere. Notarization needs stored credentials once:

```sh
xcrun notarytool store-credentials mirrordeck \
    --apple-id you@example.com --team-id YOURTEAM
```

The app-specific password comes from
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords.

## How it works

```
iPhone ──(AirPlay: Bonjour + pairing + FairPlay + RTSP/H.264)──▶ libMirrorCore.dylib
                                                                     │ decrypted Annex-B H.264
                                                                     ▼
                                              Swift app: VideoPipeline ▶ AVSampleBufferDisplayLayer
```

- **`native/`** — `mirror_bridge.c` wraps the vendored AirPlay protocol core
  behind a two-function C API (`mb_start` / `mb_stop`), built as
  `libMirrorCore.dylib`. All third-party code lives here and nowhere else.
- **`Sources/MirrorDeck/`** — the app: menu bar shell, native mirror window,
  and H.264 → `AVSampleBufferDisplayLayer` pipeline (hardware decode).
- **`vendor/`** — [UxPlay](https://github.com/FDH2/UxPlay), fetched at a pinned
  commit by `scripts/bootstrap.sh` rather than committed.
- **`web/`** — the project landing page.

## Roadmap

- [ ] Audio playback (AAC-ELD decode via AudioToolbox)
- [ ] H.265 support (feature bit 42 + HEVC format descriptions)

Contributions welcome.

## License

GPL-3.0 — see [LICENSE](LICENSE).

MirrorDeck is GPL-3.0 because `playfair`, the FairPlay handshake implementation
it depends on, is GPL-3.0 and cannot be removed: `fairplay_decrypt()` recovers
the media keys, so nothing mirrors without it.

Third-party components, all confined to `libMirrorCore.dylib`:

| Component | Origin | License |
|---|---|---|
| AirPlay/RAOP core | UxPlay `lib/` | LGPL-2.1-or-later |
| `playfair` (FairPlay) | UxPlay `lib/playfair/` | GPL-3.0 |
| llhttp | UxPlay `lib/llhttp/` | MIT |
| libplist | libimobiledevice | LGPL-2.1-or-later |
| libcrypto | OpenSSL 3 | Apache-2.0 |

The LGPL relinking obligation is met structurally: those components live in a
replaceable shared library exporting only `mb_start` and `mb_stop`, so anyone
can rebuild it with `./native/build.sh` and substitute their own build. See
[licenses/NOTICE.md](licenses/NOTICE.md).

### A note on FairPlay

Two different things share the FairPlay name, and they are worth separating.

**FairPlay Streaming** is the content DRM protecting Netflix, Disney+ and Apple
TV+. It needs hardware-backed keys. MirrorDeck does not have them and cannot
obtain them — protected video will black out when mirrored, exactly as it does
with every other third-party receiver. iOS excludes protected layers from the
mirrored capture before anything is encoded, so this is enforced by the phone,
not by us.

**FairPlay SAP** is the session handshake, and it is what `playfair` implements.
It answers an authentication challenge so the phone will release the key for
*its own screen*. That is all it does: `fairplay_decrypt()` turns the 72-byte
key the phone sends during setup into the 16-byte AES key for the mirroring
stream. It is not optional — without it no session starts at all.

So MirrorDeck decrypts no copyrighted work. It authenticates to a protocol so a
device can show its own screen on its owner's computer. Every open-source AirPlay
receiver depends on the same handshake, and the commercial ones reverse-engineer
it too.

Following the practice of [UxPlay](https://github.com/FDH2/UxPlay) and
[RPiPlay](https://github.com/FD-/RPiPlay), on which this work builds:

> This project is built from freely available information and is intended for
> educational purposes. It is the user's responsibility to comply with local
> law. It depends on a third-party GPL library for the FairPlay handshake whose
> legal status is unclear. If you represent Apple and object to that library or
> its use here, please open an issue or contact the maintainer and appropriate
> steps will be taken.

---

Built on the work of [UxPlay](https://github.com/FDH2/UxPlay), whose AirPlay
implementation makes the mirroring possible. Not affiliated with or endorsed
by Apple Inc.
