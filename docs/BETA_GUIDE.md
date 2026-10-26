# Prune beta: tester guide

Thanks for testing Prune. It takes about 20 minutes. You need a Windows
laptop, an Android phone and a USB cable that carries data (not just
charging).

## What Prune does

You plug your Android phone into your laptop. Prune reads it and lists what
is safe to remove: payment and chat screenshots, duplicates, blurry shots,
WhatsApp copies, old installers, old downloads and caches. Each pick comes
with its picture and the reason it was chosen.

**In this beta Prune never changes your phone.** It only reads. The Clean
button is switched off for real phones, so nothing can be trashed or
deleted. What we need from you is to tell us whether Prune's picks are
right.

## Your privacy

- Everything happens on your laptop. Prune sends nothing over the internet:
  no account, no upload, no analytics.
- Photos are copied to the laptop one batch at a time so they can be
  measured. The copies are deleted straight away.
- Prune keeps one file on the laptop: `%LOCALAPPDATA%\Prune\prune.db`. It
  holds file names, sizes and measurements. Text read from your screenshots
  is stored encrypted with your Windows account, so another Windows user on
  the same laptop can't read it.
- When you're done, choose **Forget this phone on this laptop…** on the home
  screen to delete everything Prune saved about it.

## 1. Install

1. Unzip `Prune-beta.zip` anywhere, for example to `Documents\Prune`.
   Keep all the files together: the `adb` folder and `PruneVision.exe` must
   stay next to `Prune.exe`.
2. Double-click `Prune.exe`.
3. Windows may say **"Windows protected your PC"**, because this test build
   isn't signed yet. Click **More info**, then **Run anyway**.

Requires Windows 10 or 11, 64-bit. Nothing else needs installing.

## 2. Connect your phone

Prune shows these steps on screen too.

1. On the phone, open **Settings → About phone** and tap **Build number**
   seven times. On some phones it's under **Software information**.
2. Open **Settings → Developer options** and turn on **USB debugging**.
3. Plug the phone into the laptop.
4. Unlock the phone and tap **Allow** on the "Allow USB debugging?"
   message. Tick **Always allow from this computer** if you'll test again.

Prune then reads the phone. The first time takes a few minutes, because it
checks every photo; later runs only check new ones. You can leave it
running in the background.

When you've finished testing you can turn USB debugging off again in
Developer options.

## 3. Look around

- The home screen shows how much you could free, one safe pick to start
  with, and the groups.
- Open **Review** to see everything. Groups fold open and shut, and chat
  screenshots are grouped by app and by person.
- Click any card to see it large, with **How we know**: the facts behind
  the pick. Duplicates are shown side by side with the copy Prune keeps.
- Videos and voice notes play right inside Prune. Documents show a preview;
  installers show the app's icon.

Keys in Review: arrow keys move between cards, **Space** ticks or unticks a
card, **Ctrl+A** ticks every card in the group, and **Esc** goes back.

## 4. Run the accuracy check (the important part)

1. On the home screen, choose **Check Prune's accuracy…**.
2. Prune shows its "sure" picks one at a time, a random few from each group.
3. For each one, answer as if you were cleaning your own phone:
   - **Y**: yes, remove it. Prune was right.
   - **N**: no, I'd keep it. Prune was wrong.
   - **S**: not sure, skip.
4. At the end you'll see how often Prune was right in each group. Press
   **Copy results** and paste them into your reply to us.

Copy results copies only the percentages: no file names, no pictures,
nothing personal.

## 5. Tell us

Send us:

- The copied accuracy results.
- Anything Prune got wrong that worried you, described in words. Please
  don't send screenshots of your own photos or chats.
- Anything confusing, slow or broken, and roughly when it happened.
- Your phone's make and model, and your Windows version.

## Known limits in this beta

- Cleaning is off on real phones (on purpose, see above).
- Android phones only. iPhones can't be read this way.
- Photos in Google Photos' cloud aren't checked, only what is stored on the
  phone itself.
- HEIC photos (often ones sent from iPhones) are skipped unless Windows has
  Microsoft's HEIF and HEVC extensions installed.
- The app icon is a placeholder.

## If something goes wrong

- **"Plug in your Android phone" doesn't go away:** try another cable or
  USB port, and check that USB debugging is on.
- **"Allow this laptop on your phone":** unlock the phone and look for the
  Allow message. If it never shows, turn USB debugging off and on again,
  then replug.
- **It stops partway:** unplug and replug the phone. Prune carries on where
  it left off.
