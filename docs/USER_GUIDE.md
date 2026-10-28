# Prune 1.0: user guide

Prune frees space on your Android phone from your Windows laptop. You need
a Windows 10 or 11 laptop (64-bit), an Android phone and a USB cable that
carries data (not just charging).

## What Prune does

You plug your Android phone into your laptop. Prune reads it and lists what
is safe to remove: payment and chat screenshots, duplicates, blurry shots,
WhatsApp copies, old installers, old downloads and caches. Each pick comes
with its picture and the reason it was chosen.

**Prune never changes anything until you press Clean.** Reading the phone,
checking photos and reviewing picks only ever read. Nothing is removed until
you review the list, untick what you want to keep, and confirm.

## Your privacy

- Everything happens on your laptop. Prune sends nothing over the internet:
  no account, no upload, no analytics.
- Photos are copied to the laptop one batch at a time so they can be
  measured. The copies are deleted straight away.
- Prune keeps one file on the laptop: `%LOCALAPPDATA%\Prune\prune.db`. It
  holds file names, sizes, measurements and a record of each clean-up. Text
  read from your screenshots is stored encrypted with your Windows account,
  so another Windows user on the same laptop can't read it.
- To delete everything Prune saved about a phone, choose **Forget this
  phone on this laptop…** on the home screen.

## 1. Install

Use either file below; both hold the same app.

- **Installer (easiest):** run `Prune-1.0.0-Setup.exe`. It installs for
  your Windows account only, needs no administrator rights, and adds Prune
  to the Start menu. To remove Prune, use **Settings → Apps**. Uninstalling
  also deletes what Prune saved about your phone, but leaves your
  **Prune Backups** folder alone.
- **Portable:** unzip `Prune-1.0.0.zip` anywhere and double-click
  `Prune.exe`. Keep the files together: the `adb` folder and
  `PruneVision.exe` must stay next to `Prune.exe`.

Windows may say **"Windows protected your PC"**, because Prune isn't signed
with a paid certificate. Click **More info**, then **Run anyway**. Windows
asks only the first time.

## 2. Connect your phone

Prune shows these steps on screen too.

1. On the phone, open **Settings → About phone** and tap **Build number**
   seven times. On some phones it's under **Software information**.
2. Open **Settings → Developer options** and turn on **USB debugging**.
3. Plug the phone into the laptop.
4. Unlock the phone and tap **Allow** on the "Allow USB debugging?"
   message. Tick **Always allow from this computer** to skip this next time.

Prune's setup screen has the exact menus for Samsung, Xiaomi, Pixel,
OnePlus/OPPO/realme, Nothing, Motorola and vivo, and tells you what is
missing: a cable that only charges, or USB debugging still off. On Samsung,
**Auto Blocker** (Settings → Security and privacy) blocks USB debugging;
turn it off while you use Prune.

Prune then reads the phone. The first time takes a few minutes, because it
checks every photo; later runs only check new ones. You can leave it
running in the background.

When you've finished you can turn USB debugging off again in Developer
options.

## 3. Review the picks

- The home screen shows how much you could free, one safe pick to start
  with, and the groups.
- Open **Review** to see everything. Groups fold open and shut, and chat
  screenshots are grouped by app and by person.
- Click any card to see it large, with **How we know**: the facts behind
  the pick. Duplicates are shown side by side with the copy Prune keeps.
- Videos and voice notes play right inside Prune. Documents show a preview;
  installers show the app's icon.
- Untick anything you want to keep. Only ticked items are cleaned.

Keys in Review: arrow keys move between cards, **Space** ticks or unticks a
card, **Ctrl+A** ticks every card in the group, and **Esc** goes back.

## 4. Clean

Press **Clean**. Prune shows exactly what will happen and waits for you to
confirm.

- **Most items go to the phone's Trash.** Photos, videos and other files
  Android lists in its gallery are moved to the phone's own Trash. You can
  restore them on the phone for 30 days, or with **Undo** in Prune.
- **Hidden items are backed up to this laptop first.** Some files, such as
  WhatsApp's sent copies, are hidden from Android's gallery and have no
  Trash. Prune copies them to the **Prune Backups** folder in your Windows
  user folder before removing them. Backup is on by default. If you turn it
  off, Prune asks you to tick "I understand these items can't be recovered"
  before it will continue.
- **Prune checks each file again just before acting.** If the phone now
  lists something else under that name, the file is left alone.
- **Undo.** When a clean-up finishes, **Undo** takes items back out of the
  phone's Trash and copies hidden items back from the laptop backup.
- **Every step is recorded.** Prune writes each step to a journal on this
  laptop before doing it. If the cable comes out halfway, nothing is lost:
  trashed items are in the phone's Trash, and with backup on, hidden items
  were copied to this laptop before they were removed.

Backups stay in **Prune Backups** until you delete them yourself. Once
you're happy with a clean-up, you can delete its folder to free laptop
space.

## Check Prune's accuracy (optional)

On the home screen, choose **Check Prune's accuracy…**. Prune shows its
"sure" picks one at a time, a random few from each group. Answer as if you
were cleaning your own phone: **Y** to remove, **N** to keep, **S** to skip.
At the end you'll see how often Prune was right in each group. **Copy
results** copies only the percentages: no file names, no pictures.

## Limits

- Android phones only. iPhones can't be read this way.
- Photos in Google Photos' cloud aren't checked, only what is stored on the
  phone itself.
- HEIC photos (often ones sent from iPhones) are skipped unless Windows has
  Microsoft's HEIF and HEVC extensions installed.

## If something goes wrong

- **"Plug in your Android phone" doesn't go away:** try another cable or
  USB port, and check that USB debugging is on.
- **"Allow this laptop on your phone":** unlock the phone and look for the
  Allow message. If it never shows, turn USB debugging off and on again,
  then replug.
- **It stops partway:** unplug and replug the phone. Prune carries on where
  it left off.
- **A clean-up stopped halfway:** reconnect the phone and Prune reads it
  again. Nothing is lost: trashed items can be restored from the phone's
  Trash, and backed-up hidden items are in **Prune Backups**.
