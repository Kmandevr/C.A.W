# C.A.W Privacy Policy (open alpha and beta)

**Draft, 2026-11-12. Not yet reviewed by a lawyer.**

This policy covers C.A.W's testing releases: the **open alpha** (the public app, versions like 1.0.0-alpha.1) and **beta** builds (the Beta channel's builds of changes not yet in the alpha). Everyone using them is a tester. It is written to be read in full.

## The short version

- C.A.W sends **anonymous data about how well it runs on your device**: device specs, performance and which built-in features are used.
- It collects **nothing about you**: no name, account, email (unless you choose to add one to feedback), project, audio, MIDI, file path, location or ID that follows you.
- **Everything collected is public** in [this repository](https://github.com/Kmandevr/C.A.W-Telemetry), so anyone, including you, can see exactly what was sent.
- In the open alpha and beta it's **on by default**. Turn it off at any time: **Settings › About and beta › Privacy** (Settings is in the project menu, which opens from the crow logo). In a future official release it will be off unless you turn it on.
- You can see, check and delete your own reports in **Settings › About and beta › Privacy › My data**.

## What is sent

While telemetry is on, at most one report a day, plus one report each time you run the **Benchmark** (Settings › Performance) (at most 10 reports a day in all), containing:

- **The app:** version (which says whether it's an alpha or beta build), engine version, whether it's a testing or official release, the day the report covers (no time of day).
- **Your device:** platform (Android, iOS, Windows, macOS or Linux) and processor architecture (such as arm64 or x64), the OS name and version, the device's maker, model and type (phone, tablet, laptop, desktop), CPU name and number of core types with their top speeds (rounded), memory (rounded to a GB), graphics renderer name, screen size (rounded), pixel density and refresh rate, audio settings (backend, buffer size, sample rate, exclusive or shared mode, and how audio comes out: built-in, USB, Bluetooth and so on), and the app's performance profile (Full Experience, Balanced, Lightweight or Minimal) and Sound quality setting.
- **Peripherals:** the kinds of devices connected (audio interface, MIDI controller, headphones, keyboard, gamepad and so on), how they're connected, and their maker's product name and USB ids. Never a name you've given a device (like "Sam's headphones"), a serial number or a hardware address.
- **Performance:** CPU-load spread, audio dropouts, the slowest audio callback, frame times, startup time, thermal and battery-saver events, and whether the system's audio scheduling help was on.
- **Use of the app:** minutes open and playing (rounded to 5), minutes on each screen, how often each **built-in** instrument and effect is used, and a size range for your project (for example "5–8 tracks").
- **Benchmark results,** if you ran the Benchmark: how each test went (comfortable, tight or over budget), how many tracks, voices and effects your device held, and what took the most time.
- **Errors:** the type of error and where in C.A.W's own code it happened, with a count.

The exact format is published in [PLAN.md](PLAN.md#report-schema-v1). The relay drops anything not on that list, and rounds numbers itself so nothing more exact can be published.

## What is never sent

Your name, accounts (including GitHub), email or contact details, IP address, location, contacts, projects or their names, audio, recordings, the notes you play, code you write, names of your own components or presets, names you've given your devices, serial numbers or hardware addresses, file names or paths, or any identifier that links one report to another or to you.

Each report carries a random **receipt** made on your device for that one report. Your device keeps the list so it can show you your reports; nothing else connects them.

## Where it goes

1. Your device sends the report over HTTPS to a small relay on Cloudflare's free Workers platform.
2. The relay checks it, keeps it in a Cloudflare D1 database briefly, and within about an hour publishes it as a file in this public GitHub repository, under `data/`.
3. Once a week a summary is published under `summaries/`.

The relay does not store IP addresses. To limit abuse it counts requests per sender using a one-way scrambled version of the address, made with a key that is replaced every day and deleted the next day, so senders can't be traced or linked across days.

Cloudflare and GitHub process the requests as hosting providers, under their own privacy policies. Cloudflare, like any web service, sees the connection's IP address while handling it.

## Update check

Separately from telemetry, C.A.W checks GitHub Releases for updates at most once a day, through an unauthenticated request to api.github.com that sends nothing about you beyond what any web request carries (your IP address and the generic user agent "CAW-app"). You can turn the check off in Settings › About and beta › Updates.

## Feedback

If you use **Send feedback** in the app (in the project menu, or Settings › About and beta › Privacy), your text and any attachments you choose (device info, the last Benchmark result, an error log; each shown to you before sending) are posted as a **public** Issue in this repository. Please don't include personal details. If you add a contact email, it is **not** published: it's kept privately for up to 180 days so the developer can reply, then deleted.

## Your choices

- **Turn it off:** Settings › About and beta › Privacy. Nothing more is sent, and anything waiting to be sent is deleted from your device.
- **See it:** Settings › About and beta › Privacy › My data shows every report your device sent, exactly as sent, with a link to its public file.
- **Delete it:** Settings › About and beta › Privacy › My data › Delete my data. Your device holds a secret key for each report; with it, the relay removes the files from `data/` within about an hour.
  - Git keeps the history of a repository, and others may already have copied public files. Deleted reports may therefore remain in the repository's history and in copies made before deletion. They contain nothing about you, by design.
  - If you reinstall the app, your device's list of receipts is gone, and nobody can find your old reports for you, because nothing links them to you. To keep the list, use "Export my receipts" first.

## Retention

Published reports and summaries stay public until deleted as above, and are shown in aggregate on the [public dashboard](https://caw-telemetry.kmandevr.workers.dev/dashboard). The relay's copy of a report's contents is removed after about 13 months (400 days); it keeps only the receipt, a one-way fingerprint of its delete key and its status, so deletion keeps working. Contact emails from feedback are deleted after 180 days.

## Children

[Owner: decide whether C.A.W states a minimum age, and fill this in.]

## Changes

Changes to this policy are published in this repository, with their history. If a change adds anything to what is collected, the app will ask you again before sending it.

## Contact

Questions: open an Issue in [Kmandevr/C.A.W-Telemetry](https://github.com/Kmandevr/C.A.W-Telemetry/issues).
