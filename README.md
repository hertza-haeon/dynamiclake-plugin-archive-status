# Archive Status

<p align="center">
  <img src="icon-rounded.png" alt="Archive Status icon" width="128">
</p>

<p align="center">
  <b>Your extractions, in the notch.</b><br>
  A plugin for <a href="https://dynamiclake.com">DynamicLake</a>.
</p>

Archive Status shows in your MacBook's notch how far an archive is in being
extracted: how much is done, how fast it goes, how long is left. When it is
over, you can show the result in the Finder or open it, without looking for
it.

- **No Accessibility, no Automation.** The plugin presses nothing in any
  app. macOS may ask once to let DynamicLake into the folder an archive
  is in: see [Permissions](#permissions).
- **Works with** MacPacker, The Unarchiver, Keka and Archive Utility (what
  a double-click on an archive in the Finder uses).
- **Stays on your Mac.** The plugin sends nothing over the internet.

## Contents

- [What you need](#what-you-need)
- [Install](#install)
- [Permissions](#permissions)
- [What you see](#what-you-see)
- [The buttons](#the-buttons)
- [Several extractions at once](#several-extractions-at-once)
- [Settings](#settings)
- [Good to know](#good-to-know)
- [If something goes wrong](#if-something-goes-wrong)
- [What the plugin does on your Mac](#what-the-plugin-does-on-your-mac)
- [Uninstall](#uninstall)

## What you need

- A Mac with [DynamicLake](https://dynamiclake.com), on macOS 14 or later.
  The plugin runs on Apple silicon and on Intel.
- [MacPacker](https://macpacker.app),
  [The Unarchiver](https://theunarchiver.com), [Keka](https://www.keka.io),
  or Archive Utility, which comes with macOS.

Nothing else: the plugin is one small program, with nothing to install
beside it.

## Install

1. Download `ArchiveStatus.dynamiclakeplugin.zip` from the
   [latest release](https://github.com/hertza-haeon/dynamiclake-plugin-archive-status/releases/latest)
   and unzip it.
2. Open **DynamicLake → Settings → Plugins**.
3. Click **Install Local** and choose the `ArchiveStatus.dynamiclakeplugin`
   folder you unzipped. Keep that exact name.

That's all: extract an archive and it shows in the notch.

To update, install the newer folder the same way and confirm **Update**.
Your settings are kept.

## Permissions

The plugin presses nothing in any app, so it needs neither Accessibility
nor Automation.

**Access to the folder an archive is in.** To know what an archive holds,
the plugin reads its list of contents. macOS counts that as DynamicLake
reading a file in that folder. So the first time you extract an archive
that is in your Desktop, Documents or Downloads folder, or on another
disk, macOS may ask whether DynamicLake may access files there. It asks
once for each of these places.

- **Allow**, and everything shows. Nothing shows in the notch while the
  question is on the screen.
- **Don't Allow**, and an extraction there still shows its pill and how
  far it is, counted on the archive's own size. With The Unarchiver and
  Keka it ends on `Done` instead of `Complete`: the plugin can't check
  the files. With MacPacker its card goes away at the end without a word.

You can change your answer in **System Settings → Privacy & Security →
Files & Folders → DynamicLake**.

## What you see

An extraction shows in two ways:

- **The pill**, in the closed notch: the archive's type on the left, a
  progress ring or a status symbol on the right.
- **The sneak peek**, the larger view that opens when you point at the
  notch: a button, a line of text and a percentage. It also opens by itself
  when an extraction is over.

The archive's type is its extension in a blue circle (`zip`, `rar`, `7z`).
An extraction starts with a blue archive box and shows its type 4 seconds
later.

| The extraction is… | Pill, right side | Sneak peek | Buttons |
| --- | --- | --- | --- |
| Waiting (the app has the archive and has written nothing yet) | ring that spins | `Waiting • photos.zip` | none |
| Under way | progress ring | `0.85/2.56GB · 11 seconds` and `33%` | Show in Finder |
| Stalled (nothing written for 15 seconds) | red **…** | `Stalled • photos.zip` and `33%` | Show in Finder |
| Complete | green **✓** | `Complete • photos.zip` | Show in Finder, Open |
| Done (extracted, and the plugin couldn't check its files) | grey **–** | `Done • photos.zip` | Show in Finder, Open |
| Stopped short (canceled, or failed) | red **✕** | `Stopped • photos.zip` | Show in Finder, when something was left |
| Incomplete (extracted to the end, with files missing) | red **○** | `Incomplete • photos.zip` | Show in Finder |

While it extracts, the line reads the amount and the total (`294/871MB`, or
`0.85/2.56GB` from 1 GB), then the time left, the speed, or both in turn:
your choice in [Settings](#settings).

The card goes away after its sneak peek. A name too long to fit stays still
for 3 seconds, then scrolls.

## The buttons

| Button | What it does |
| --- | --- |
| **Show in Finder** | Shows what was extracted, selected in the Finder. While the extraction is under way: what is there of it so far. |
| **Open** | Opens what was extracted, as a double-click would: a folder in a Finder window, a file in its app. |

There is no Stop button: the plugin never acts on another app's extraction.
Cancel it in the app that extracts.

## Several extractions at once

The plugin is one card in the notch, however many extractions are running.

- **Their number** takes the place of the archive's type in the pill.
- **Their sizes are added up:** one ring, one percentage, one pair of
  amounts for all of them. The ring steps back when another extraction
  joins.
- **The time left** is that of the extraction that finishes last.
- **At the end, one card:** `3 Extractions Completed`, with Show in Finder
  for all of them. If some stopped short: `2/3 Extractions Completed`, with
  the red **✕**. If one of them is only `Done`, the card says `Done` for
  `Completed`: `3 Extractions Done`, with the grey **–**.
- **An extraction that begins when all the others are over** starts afresh,
  on the same card.
- **The Unarchiver takes the archives it is given one after the other.**
  Those that wait for their turn are counted from the start, in the number
  and in the total. Keka and Archive Utility extract them at the same
  time.

One extraction alone keeps its own card, with its name and both buttons.

## Settings

In **DynamicLake → Settings → Plugins**, right-click **Archive Status** and
choose **Settings**. Changes apply within a few seconds.

| Setting | Default | What it does |
| --- | --- | --- |
| **File-Type Icons** | On | Shows the archive's type in a blue circle. Off: the blue archive box. Several extractions always show their number. |
| **Extraction Details** | Time | What follows the amount while extracting. **Speed**: `120 MB/s`. **Time**: `2 min 34 s`, then `45 seconds` in the last minute. **Both**: each in turn, 3 seconds at a time. |
| **Delayed Display** | On | While you're away, extractions that end don't open the notch: the card waits, closed. When you're back, it opens. What ended one by one meanwhile is said on one card. |
| **Away After** | 1 min | You count as away when the screen is locked, or after this long without touching the keyboard, mouse or trackpad: 1, 3, 5 or 10 minutes. |
| **Sneak Peek Duration** | 5 s | How long the sneak peek stays open when the extractions are over: 3, 5, 8 or 10 seconds. |
| **Remain Visible** | 0 s | How long the closed pill stays after that sneak peek, from 0 to 30 seconds. |
| **Minimum Duration** | 10 s | How long an extraction must take, at least, to show at all, from 0 to 60 seconds. A shorter one shows nothing: no pill, no card. At 0 every extraction shows. |

## Good to know

**Timing**

- The pill comes with the first file an extraction writes. With Minimum
  Duration above 0 it comes about two seconds later: the plugin can't know
  beforehand how long an extraction will take, and works it out from its
  speed. An extraction it expected to be short shows after all if it turns
  out longer.
- With The Unarchiver or Keka and Minimum Duration at 0, the pill comes as
  soon as the app has the archive, and reads `Waiting` until its first
  file is written: while the app reads the archive through, or asks you
  for a password.
- An app may need a while after the last file is written: Keka, for one,
  goes over every file of an archive that was downloaded from the
  internet. The ring is full meanwhile, and `Complete` comes when the app
  is done.
- An extraction of less than a second may not be seen at all.

**Amounts**

- Sizes are counted as the Finder counts them: 1 GB is 1,000,000,000
  bytes.
- The amounts are those of the files once extracted, read from the
  archive's own list of contents: `zip`, `rar`, `7z`, `tar`, and compressed
  tars (`tar.gz`, `tar.bz2`, `tar.xz`). A zip, a RAR or a 7z under another
  name is read the same (`cbz`, `cbr`, `jar`, `apk`, `epub`…).
- An archive of another kind (`zst`, `lz4`, `iso`, `cab`, `cpio`…) is
  followed with The Unarchiver and Keka, by how far the app has read into
  it: the amounts are the archive's own size, and it ends on `Done`.
- A compressed tar has to be unpacked to be read. A large one (from about
  100 MB for a `tar.bz2`, more for a `tar.xz` or a `tar.gz`) takes longer
  than the plugin can stand still for: its list is then read on the side
  while the app extracts, which keeps one processor core busy for as long.
  Until the list is there, the extraction is followed by how far the app
  has read into the archive, and the amounts are the archive's own size.
  At the end its files are checked as any archive's are.
- An extraction whose size can't be told at all keeps the ring spinning and
  shows the amount written alone. Beside others that have a size, it counts
  in their number only.
- An archive in several parts (`photos.7z.001`, `photos.7z.002`…, or
  `photos.zip` with `photos.z01`, `photos.z02`…) is one extraction, under
  the name of the part you open.

**How it ends**

- A canceled extraction and a failed one look the same from outside: both
  read `Stopped`.
- When the plugin can't tell whether an extraction got to its end, its card
  goes away without a word.
- `Complete` means every file of the archive is there, with its size. The
  plugin doesn't read what is in the files.
- `Incomplete` means the app went through the archive to its end and
  some of its files are missing or cut short: a damaged archive.
- `Done` means the app put what it extracted in place, and the plugin
  couldn't check the files: it had no list of the archive's contents (an
  archive of a kind it can't read, a folder DynamicLake isn't allowed
  into, or a large compressed tar whose list wasn't read 20 seconds after
  the app was done). With The Unarchiver and Keka.

**The notch and other apps**

- When something else has the notch (music, for example), the extraction is
  the small capsule beside it, with the archive's type or the number. When
  it is over, its card takes the notch for the usual time, with its sneak
  peek and its buttons. Then the other activity is back.

**What isn't shown**

- Making an archive (compressing).
- Extractions by other apps than MacPacker, The Unarchiver, Keka and
  Archive Utility.
- With Archive Utility, a `rar`: Archive Utility doesn't extract those.
- With MacPacker and Archive Utility, an archive that is neither a zip, a
  RAR, a 7z nor a tar (`iso`, `cab`, `zst`…).
- With MacPacker, a compressed tar that was already open in MacPacker when
  the plugin started, or one so small that MacPacker unpacks it in a blink.

## If something goes wrong

**Nothing shows in the notch when an extraction starts.** A short
extraction shows nothing: look at **Minimum Duration** in the
[settings](#settings). An app that first asks you something (a password,
access to a folder) shows once it starts extracting. Otherwise quit
DynamicLake and open it again.

**The card says `Done` instead of `Complete`, or the amounts are those of
the archive itself.** The plugin couldn't read the archive's list of
contents, or not yet: DynamicLake isn't allowed into the folder the
archive is in (see [Permissions](#permissions)), or it is a large
compressed tar.

**DynamicLake says the plugin can't be run.** In Terminal:

```bash
chmod +x ArchiveStatus.dynamiclakeplugin/archive-status
```

**Show in Finder or Open does nothing.** What was extracted isn't where it
was: it was moved, renamed or deleted since.

**Still stuck?** The plugin keeps a log of what it saw and what it showed:

```
~/Library/Logs/ArchiveStatus/plugin.log
```

Its last lines usually tell what happened.

## What the plugin does on your Mac

- It **asks macOS which files the unarchiver has open**, and how far into
  the archive it has read. Nothing is opened in the unarchiver, and nothing
  is pressed in it.
- It **reads the archive's list of contents**, to know how much there is to
  extract. A compressed tar is unpacked for that in memory, by macOS's own
  archive library; nothing is written. For a large one that takes as long
  as extracting it does, on one processor core. This is the one thing
  macOS may ask you about, in DynamicLake's name: see
  [Permissions](#permissions).
- It **looks whether the extracted files are there**, one by one, by their
  names. It doesn't read them. MacPacker extracts into a hidden folder of
  its own first (`.MacPacker-…`), whose name can't be guessed: for that
  one, the plugin looks at the names in the folder being extracted to.
- It **never writes** into an archive, into what was extracted or into your
  folders. All it writes is its own log.
- Its two buttons use macOS's `open` command, for the Finder and for the
  extracted item. The plugin starts no other program.
- Whether you're away is read from macOS: how long since the last input,
  and whether the screen is locked. Nothing of what you type or click is
  seen.
- It **sends nothing** over the internet.
- The plugin is the program `archive-status`. Its source is in
  [the repository](https://github.com/hertza-haeon/dynamiclake-plugin-archive-status).

## Uninstall

1. In **DynamicLake → Settings → Plugins**, right-click **Archive Status**
   and choose **Uninstall**.
2. Optionally, delete what it left behind:

```
~/Library/Logs/ArchiveStatus/
```

---

<sub>Copyright © 2026 Hertza Haeon. Archive Status is released under the
[Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).</sub>

<sub>This plugin is an independent project. It is not affiliated with, or
endorsed by, DynamicLake, MacPacker, MacPaw (The Unarchiver), Keka or Apple.</sub>
