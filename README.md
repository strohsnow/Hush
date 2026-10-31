# Hush

A tiny macOS menu bar app that stops the clicks and pops in wired headphones.

macOS powers down the headphone output during silence and wakes it up when sound starts again, and many headphones and DACs click when that happens. Hush keeps the output awake with a stream of digital silence, so there is nothing to click.

## Features

- Works with the built-in 3.5 mm jack and wired USB DACs you choose
- Runs only while a selected output is in use; speakers and Bluetooth are left alone
- Lets your Mac sleep on its usual schedule
- No settings to tune

## Requirements

- macOS 13 or later
- Xcode Command Line Tools: `xcode-select --install`

## Install

```bash
git clone https://github.com/strohsnow/Hush.git
cd Hush
./build.sh install
```

This builds the app, copies it to `/Applications` and launches it. Hush appears in the menu bar, not in the Dock.

## Usage

- **Enabled** turns Hush on or off.
- **Outputs** picks which outputs to keep awake. The headphone jack is on by default; connected USB DACs show up here.
- **Open at Login** starts Hush automatically.

## How it works

While a selected output is active, Hush plays digital silence to it. A running audio stream also keeps macOS from going to sleep, so Hush stops the stream shortly before your display would turn off, and resumes as soon as you're back. If another app is playing audio, the stream is left running until it stops (macOS 14 and later).
