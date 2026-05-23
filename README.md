# Cruisin

Native SwiftUI voice-guide prototype for a Kalakaua Avenue Honolulu route replay.

Cruisin launches directly into a driving screen with a MapKit map, simulated route position, nearby local facts, narration status, Start/Pause/Replay controls, and an audit panel showing why narration was or was not selected. For OpenAI Voice Hack Night, the current submission adds AI Guide Mode: the bundled Kalakaua Avenue route replay ranks nearby local facts, streams compact route/context state into OpenAI Realtime with `gpt-realtime`, and lets the model speak concise narration while preserving local fallback paths.

## Event Mode Boundaries

- AI Guide Mode uses OpenAI Realtime with `gpt-realtime` for live spoken narration over the simulated Honolulu route. It should send only compact context: current route label, nearby ranked facts, recent narration state, and any driver preference or question such as "skip food," "history angle," or "what am I passing now?"
- AI Guide Mode uses push-to-talk interruption for the demo: when the driver presses and holds the mic, the app pauses any current AI audio, streams that short voice turn to Realtime, and treats release as the end of the question so the guide can answer and continue from the simulated position after the interruption.
- Local Guide mode keeps the same route replay, bundled Honolulu facts, local ranking, cooldowns, spoken-ID dedupe, and audit panel without requiring OpenAI network access.
- The AVFoundation fallback is the local speech boundary. When AI Guide Mode is unavailable, disabled, interrupted by missing secrets, or blocked by network/API failure, narration should fall back to `AVSpeechSynthesizer` speaking selected local facts.
- The demo is not a navigation product. It does not use live GPS, turn-by-turn directions, traffic, CarPlay, backend infrastructure, multi-city routing, hidden/background recording, or runtime scraping.

## Local Secrets

Copy `.env.example` to `.env` and fill only the providers used by the current prototype:

```sh
cp .env.example .env
$EDITOR .env
```

For AI Guide Mode, set `OPENAI_API_KEY` or `OPENAI_REALTIME_API_KEY` in `.env` or another ignored local config file. Do not commit real keys, paste keys into Swift source, store keys in bundled JSON, add keys to project settings, or include keys in screenshots/logs. `.env` and `.env.local` are ignored; `.env.example` must stay key-free.

Local Guide mode and the AVFoundation fallback do not require an OpenAI key. If `OPENAI_API_KEY` is missing or invalid, run the demo in Local Guide mode and call out the fallback behavior.

## Project Layout

- `Cruisin.xcodeproj`: iOS app project with the `Cruisin` app target and focused `CruisinTests` logic target.
- `Cruisin/`: SwiftUI app source plus bundled `HonoluluFacts.json` and `HonoluluRoute.json`.
- `Scripts/generate_honolulu_seed.py`: regenerates the offline Honolulu data pack.

## Data Pack

The generated seed pack currently contains 50 strict Kalakaua Avenue / Waikiki Beach facts and 46 road-following Kalakaua Avenue replay route waypoints. Every fact has:

- stable `id` for dedupe,
- `name`, `category`, optional `subcategory`, tags, coordinates, and priority,
- short narration text,
- `sourceName`, `sourceURL`, `sourceURLs`, and `sourceConfidence` attribution,
- ranking fields for cultural/historic importance, visual prominence, drive-by value, sensitivity, safety flags, evergreen/freshness, and audit metadata.
- scope fields for review: `addressOrFrontage`, `onKalakaua`, `onWaikikiBeach`, `scopeDecision`, and `scopeNotes`.
- optional event fields for time-sensitive entries: `eventStartDate`, `eventEndDate`, and `recurrence`.

Regenerate the bundled resources:

```sh
python3 Scripts/generate_honolulu_seed.py
```

The generator is offline-first: it normalizes static seed facts, assigns source-quality/value defaults, dedupes by canonicalized name and coordinates, and writes both `HonoluluFacts.json` and the human-reviewable `HonoluluFactsReview.csv`. The current seed source is intentionally narrow: a fact must be literally on Kalakaua Avenue, on Waikiki Beach/Kuhio Beach, or a beach-edge surf/reef/shoreline feature directly visible from that corridor. Its extension points are source-shaped so later agents can add OSM/Overpass, Wikidata/Wikipedia, official civic/park/museum/historic-register sources, or local culture/food/music/architecture feeds without changing the app runtime contract.

Runtime ranking is explainable. `NarrationEngine` scores nearby facts with intrinsic value, preference match, proximity, route relevance, novelty, source confidence, visual prominence, drive-by value, quiet-mode interruption cost, and safety/sensitivity penalties. Each candidate carries score components plus short audit reasons; the realtime payload sends only the compact top-ranked facts and instructs the model to use only those staged facts.

The app does not fetch live POI, route, navigation, traffic, or map-search data at runtime after these files exist in `Cruisin/`. AI Guide Mode still makes OpenAI Realtime calls when enabled with a key.

## Build And Run

Before building or visually validating, confirm you are in the checkout you mean to run:

```sh
pwd
git rev-parse --show-toplevel
git branch --show-current
git status -sb
```

Recommended simulator target:

```sh
xcodebuild \
  -project Cruisin.xcodeproj \
  -scheme Cruisin \
  -configuration Debug \
  -derivedDataPath .derivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  build
```

To run interactively without AI Guide Mode secrets, open `Cruisin.xcodeproj` in Xcode and run the `Cruisin` scheme on an iOS simulator, or use an iOS simulator run workflow with:

- project: `Cruisin.xcodeproj`
- scheme: `Cruisin`
- bundle id: `com.avmillabs.cruisin`

To launch a simulator build with `OPENAI_API_KEY` from the ignored `.env`, export the file in the calling shell and pass it to the app with the `SIMCTL_CHILD_` prefix. `xcrun simctl launch` does not read `.env` by itself.

```sh
set -a
source .env
set +a

xcodebuild \
  -project Cruisin.xcodeproj \
  -scheme Cruisin \
  -configuration Debug \
  -derivedDataPath .derivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  build

xcrun simctl boot "iPhone 17 Pro Max" 2>/dev/null || true
xcrun simctl bootstatus "iPhone 17 Pro Max" -b

APP_PATH="$PWD/.derivedData/Build/Products/Debug-iphonesimulator/Cruisin.app"
test -d "$APP_PATH"

xcrun simctl install booted "$APP_PATH"
SIMCTL_CHILD_OPENAI_REALTIME_API_KEY="$OPENAI_REALTIME_API_KEY" \
  xcrun simctl launch --terminate-running-process booted com.avmillabs.cruisin
```

If the key is blank, expired, or the Realtime session cannot connect, keep the same simulator run and switch to Local Guide/AVFoundation fallback narration for the event demo.

## Demo Flow

Run this as a 60-90 second event demo:

1. Launch the app. The first screen is the driving surface, not a landing page.
2. Select `AI Guide`, confirm `GPT-Realtime Connected`, then tap `Replay` or `Start`.
3. Show the moving car marker, cyan Honolulu route, nearby POI pins, and ranked `Nearby Context` list.
4. Let `gpt-realtime` speak one concise route-context narration.
5. Interrupt by holding the mic while speaking, or tap the canned command: `Skip food. Give me the history angle, and keep it short.`
6. Point to the audit panel: model transcript, user utterance, compact context summary, ranked candidates, cooldown reason, and fallback/error state.
7. Relaunch without `OPENAI_API_KEY` or switch to Local Guide to show `GPT-Realtime Fallback` plus AVFoundation local narration.

## 90-Second Voice Hack Night Script

0-10 seconds: "This is Cruisin, a native SwiftUI AI guide for a replayed Honolulu drive. The route is simulated so the realtime voice demo is repeatable and does not require live driving."

10-25 seconds: Select `AI Guide`, tap `Replay`, and point out the moving route marker plus nearby context. "The app ranks bundled Honolulu facts near the current route position and keeps an audit trail of selection and cooldown decisions."

25-45 seconds: Let `gpt-realtime` speak one concise fact from the current compact context. "Realtime gets the route label, top ranked facts, cooldown state, and recent narration, not the whole data pack."

45-65 seconds: Press and hold the mic, or tap the canned interruption. "Now I interrupt with: skip food, give me the history angle, and keep it short. `gpt-realtime` pivots while the route replay keeps moving."

65-80 seconds: Point to the audit panel. "This is the context ledger: model transcript, user utterance, ranked candidates, distance/category reasons, cooldown decisions, and fallback status."

80-90 seconds: Close with the fallback. "If Wi-Fi or API access fails, the same route replay continues in Local Guide mode with AVFoundation speech, so the demo still works without live driving or turn-by-turn navigation."

## Application Materials

Short one-liner:

Cruisin is a native iOS realtime AI guide that uses `gpt-realtime` to narrate a simulated Honolulu drive from compact local route context, with an auditable Local Guide fallback.

Copy-pastable answer:

Project name: Cruisin AI Guide Mode

Repo: https://github.com/jskoiz/cruisin

Demo video or live demo link: add hosted video link here before submitting the form.

Cruisin is a native SwiftUI iOS prototype for OpenAI Voice Hack Night. It replays a simulated Honolulu route, ranks bundled nearby facts, and sends compact route context to OpenAI Realtime with `gpt-realtime` so the guide can speak concise narration.

What I am building with OpenAI realtime models: AI Guide Mode, a spoken route guide that can respond to driver questions while the simulated drive continues. In the demo, push-to-talk can interrupt the guide with "Skip food. Give me the history angle, and keep it short," and `gpt-realtime` uses the current route context plus local preferences to answer briefly.

Relevant links: the public repo is https://github.com/jskoiz/cruisin. Add the hosted demo video link alongside the repo link before submitting the form.

Models used: OpenAI Realtime with `gpt-realtime`.

Scope and safety: the demo uses simulated route replay only. It is not live driving, not turn-by-turn navigation, not traffic-aware, not CarPlay, and not a backend or scraping system. If credentials, Wi-Fi, or API access fail, the same route replay continues in Local Guide mode with AVFoundation speech.

## Current Validation

The public `main` branch was prepared for OpenAI Voice Hack Night submission on May 22, 2026 HST at commit `eb2bac7`.

- The GitHub repository is public: https://github.com/jskoiz/cruisin
- The tracked tree excludes `.env`, `.env.local`, `.derivedData/`, `dist/`, logs, user-specific Xcode state, and local secret config paths.
- A current-tree secret scan found no committed OpenAI keys, AWS access keys, Linear keys, private keys, or populated OpenAI environment variables.
- A history scan found only environment-variable placeholders such as `$OPENAI_API_KEY`, not raw secret values.
- `xcodebuild -project Cruisin.xcodeproj -scheme Cruisin -configuration Debug -derivedDataPath .derivedData -destination 'generic/platform=iOS Simulator' build` succeeded.
- `xcodebuild -project Cruisin.xcodeproj -scheme Cruisin -configuration Debug -derivedDataPath .derivedData -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test` succeeded with 10 focused logic tests.

Local demo media can be packaged from ignored `.derivedData/demo-artifacts/` when present, but media files and secret files are intentionally not committed to the public repo.

Build the repeatable local submission pack after the video and screenshots exist:

```sh
python3 Scripts/package_voice_hack_night.py
```

The script rebuilds ignored `dist/voice-hack-night/`, copies only video and screenshot files from ignored `.derivedData/demo-artifacts/`, extracts this README's `Application Materials` section into `application-answers.md`, writes `manifest.json`, and writes SHA-256 hashes to `CHECKSUMS.txt`. It also verifies `.derivedData/`, `dist/`, `.env`, `.env.local`, and local secret config paths are protected by `.gitignore` before packaging.

Treat AI Guide Mode validation separately: launch with an ignored `OPENAI_API_KEY`, confirm `gpt-realtime` speaks from compact context, verify push-to-talk interruption behavior, then confirm Local Guide/AVFoundation fallback still works with the key removed.

## Risk And Fallback Notes

- Wi-Fi/API failure: continue the same replay in Local Guide mode and use AVFoundation narration.
- Missing or invalid `OPENAI_API_KEY`: do not block the demo; keep the key out of the repo and demonstrate the local fallback path.
- Realtime latency or push-to-talk interruption failure: narrate the currently selected local fact with AVFoundation and use the audit panel to explain what would have been sent to `gpt-realtime`.
- No live driving: route position is simulated from bundled waypoints for repeatable event demos.
- No turn-by-turn, traffic, or CarPlay: MapKit is used as a visual route replay surface only.
- No backend or runtime scraping: the app uses bundled Honolulu facts with source URLs.

## Submission Checklist

- Paste the public repo link: https://github.com/jskoiz/cruisin
- Add a hosted demo video link in the application form.
- Run the final dry run with a valid ignored `OPENAI_API_KEY` and the expected network.
- Keep keys out of screenshots, logs, commits, and recordings.
