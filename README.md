# Bass Haptics

Pick a song (MP3, M4A, WAV…) → the app analyses its bass → plays the song while the iPhone's Taptic Engine follows the low end.

Made for an **iPhone 15 Pro Max on iOS 27**. It runs on iOS 17 and later and needs a real iPhone (no haptics in the Simulator or on iPad).

## What the haptics do

| Bass in the song | Haptic |
|---|---|
| around **25–30 Hz** (sub bass) | **sharpness lowest** (0.0): round, deep |
| around **100–120 Hz** (punchy bass) | **sharpness highest** (1.0): crisp |
| in between | smooth sweep (log-frequency) |
| louder bass | **intensity higher**, biased upward so it stays strong (the *Intensity boost* slider) |
| no bass | silence |

How it works: the song is decoded and reduced to the 20–150 Hz band, then analysed every 10 ms for bass loudness and dominant bass frequency.
During playback one continuous Core Haptics event is steered about 60 times a second through the intensity and sharpness controls, locked to the audio clock.

## Getting it onto your iPhone

An IPA only installs on a phone if it is **signed for that phone with your own Apple ID**, so it can't be pre-built for you. These two routes get you there:

### A. No Mac: build the IPA on GitHub (free), then install it with Sideloadly or AltStore

1. Make a free GitHub account and create a **new public repository** (public repos get free build minutes).
2. Upload everything in this folder, including the hidden `.github` folder.
   If the browser skips it: *Add file → Create new file*, name it `.github/workflows/build-ipa.yml` and paste in that file.
3. Open the **Actions** tab → **Build unsigned IPA** → **Run workflow**. It takes about 5 minutes.
4. Open the finished run → **Artifacts** → download `BassHaptics-unsigned-ipa` → unzip it to get `BassHaptics-unsigned.ipa`.
5. Install that IPA with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io) (Windows or Mac, free Apple ID): drag the IPA in, sign in, press Start.
6. On the iPhone: **Settings → Privacy & Security → Developer Mode → On** (it restarts), then **Settings → General → VPN & Device Management →** trust your Apple ID.

Free Apple IDs expire apps after 7 days; just re-sign the same IPA.

### B. You have a Mac with Xcode 27

```sh
brew install xcodegen
xcodegen generate
open BassHaptics.xcodeproj
```
In Xcode: *Signing & Capabilities* → pick your Team, change the Bundle Identifier to something unique (or set `DEVELOPMENT_TEAM` / `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`), plug in the iPhone, press Run.

## Using it

Choose a song → wait for "Haptic map ready" → press play. The coloured map shows the haptics the song will get (height = intensity, colour = sharpness). *Tuning* has:

- **Intensity boost**: higher keeps the vibration strong even in quieter bass.
- **Haptic delay**: nudges haptics earlier/later against the audio (useful with Bluetooth headphones).

## If you feel nothing

- **Settings → Sounds & Haptics → System Haptics** must be on.
- Haptics only run while the app is on screen (iOS doesn't allow them in the background); the screen stays awake while playing.
- Low Power Mode can weaken haptics.

## Tweaking the mapping in code

- `BassAnalyzer.swift`: `sharpnessLowHz` (30) and `sharpnessHighHz` (100) set where sharpness hits 0 and 1; `bandLow`/`bandHigh` set the bass range; `levelRangeDB` sets how quiet bass can get before it counts as silence.
- `PlayerModel.swift`, `intensity(level:boost:)`: the intensity curve (floor and gamma).
