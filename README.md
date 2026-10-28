# Prune

<img src="design/logo/prune-icon-1024.png" alt="Prune icon" width="96" align="right">

Prune frees space on an Android phone from a Windows laptop: you plug the
phone in, Prune finds what is safe to remove, shows you why, and removes
only what you confirm. Everything happens on your laptop.

It is built for people whose galleries run to tens of thousands of images:
forwarded screenshots, payment receipts, duplicate photos, WhatsApp copies,
old installers and downloads.

## What it finds

| Group | How Prune knows |
|---|---|
| Chat screenshots | Reads the text and recognises the app (WhatsApp, Instagram, Telegram, Messenger, Discord, LinkedIn, Snapchat, text messages, AI chats); grouped by person |
| Payment screenshots | A success phrase plus proof: an amount, UPI ID or reference number |
| Other screenshots | Grouped by the app or website on screen |
| Exact duplicates | Same contents, checked by hash on the phone; the copy in the most original place is kept |
| Similar photos | Look-alike photos taken close together; the sharpest is kept |
| Blurry photos | Sharpness and detail measures; photos with people are never pre-ticked |
| WhatsApp sent copies, old voice notes, old installers, old documents, large videos, accidental short clips, caches | File rules: where it lives, age, size, and whether a newer copy exists |

Every pick shows its picture (or a PDF page, app icon or video), its file
name, and **How we know**: the facts behind it. Duplicates are shown side by
side with the copy that stays.

## Safety

- **Nothing changes until you press Clean.** Reading the phone, checking
  photos and reviewing only read.
- Items Android indexes go to the **phone's Trash** for 30 days.
- Hidden items (for example WhatsApp sent copies) are **backed up to the
  laptop first** (`%USERPROFILE%\Prune Backups`), on by default.
- Before each item is removed, Prune checks again that the file on the phone
  is still the one it listed.
- Every clean-up is recorded, so **Undo** works, even after a pulled cable.

## Privacy

- No account, no upload, no analytics, no network use. The only server is a
  private address on `127.0.0.1` used to play phone videos.
- Photos are copied to the laptop in batches to be measured, then deleted.
- One database, `%LOCALAPPDATA%\Prune\prune.db`. Text read from screenshots
  is encrypted with your Windows account (DPAPI).
- **Forget this phone** deletes everything Prune saved about a phone.

## Requirements

Windows 10 or 11 (64-bit), an Android phone with USB debugging turned on,
and a data USB cable. Nothing else to install: `adb` and the helper ship with
Prune. See [the user guide](docs/USER_GUIDE.md).

## Build from source

Needs Flutter (stable) with the Windows desktop toolchain (Visual Studio
"Desktop development with C++"), the Android SDK platform-tools (for `adb`),
and optionally Inno Setup 6 for the installer.

```powershell
.\packages\vision_helper\build.ps1      # the text-reading helper (uses Windows' own C# compiler)
cd apps\declutter
flutter run -d windows                  # run in development
cd ..\..
.\tool\package.ps1                      # dist\Prune-<version>.zip and -Setup.exe
```

Tests:

```powershell
cd packages\engine; dart test
cd ..\store; dart test
cd ..\phone_link; dart test -x emulator -x phone
cd ..\vision_helper; dart test
cd ..\..\apps\declutter; flutter test -x phone
```

Tests tagged `phone` only read from a connected phone. Tests that clean run
only on an Android emulator and skip otherwise.

## Project layout

| Folder | What it is |
|---|---|
| `apps/declutter` | The Windows app (Flutter) |
| `packages/engine` | The rules: what counts as junk, and why (pure Dart) |
| `packages/phone_link` | Talking to the phone over adb, read-only except the cleaner |
| `packages/store` | The local database |
| `packages/vision_helper` | `PruneVision.exe`: text reading, faces, previews, using Windows' built-in engines |
| `tool` | Packaging, installer and icon scripts |
| `docs` | The user guide |
| `design` | Logo and design notes |

## Limits

Android only (iPhones can't be read this way). Photos in Google Photos' cloud
aren't checked. HEIC photos need Microsoft's HEIF/HEVC extensions. The app
isn't code-signed yet, so Windows warns once on first run.
