# Cruisin

Native SwiftUI voice-guide prototype for a Kalakaua Avenue Honolulu route replay.

Cruisin launches directly into a driving screen with a MapKit map, simulated route position, nearby local facts, narration status, Start/Pause/Replay controls, and an audit panel showing why narration was or was not selected. For OpenAI Voice Hack Night, the current submission adds AI Guide Mode: the bundled Kalakaua Avenue route replay ranks nearby local facts, streams compact route/context state into OpenAI Realtime with `gpt-realtime-2`, and lets the model speak concise narration while preserving local fallback paths.

## Event Mode Boundaries

- AI Guide Mode uses OpenAI Realtime with `gpt-realtime-2` for live spoken narration over the simulated Honolulu route. It should send only compact context: current route label, nearby ranked facts, recent narration state, and any driver preference or question such as "skip food," "history angle," or "what am I passing now?"
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

The generated seed pack currently contains 65 Honolulu-area facts/POIs and 46 road-following Kalakaua Avenue replay route waypoints. Every fact has:

- stable `id` for dedupe,
- `name`, `category`, coordinates, and priority,
- short narration text,
- `sourceName` and `sourceURL` attribution.

Regenerate the bundled resources:

```sh
python3 Scripts/generate_honolulu_seed.py
```

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

To run interactively without AI Guide Mode secrets, open `Cruisin.xcodeproj` in Xcode and run the `Cruisin` scheme on an iOS simulator, or use the Build iOS Apps/XcodeBuildMCP simulator run workflow with:

- project: `/Users/jk/Desktop/cruisin/Cruisin.xcodeproj`
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
2. Select `AI Guide`, confirm `GPT-Realtime-2 Connected`, then tap `Replay` or `Start`.
3. Show the moving car marker, cyan Honolulu route, nearby POI pins, and ranked `Nearby Context` list.
4. Let `gpt-realtime-2` speak one concise route-context narration.
5. Interrupt by holding the mic while speaking, or tap the canned command: `Skip food. Give me the history angle, and keep it short.`
6. Point to the audit panel: model transcript, user utterance, compact context summary, ranked candidates, cooldown reason, and fallback/error state.
7. Relaunch without `OPENAI_API_KEY` or switch to Local Guide to show `GPT-Realtime-2 Fallback` plus AVFoundation local narration.

## 90-Second Voice Hack Night Script

0-10 seconds: "This is Cruisin, a native SwiftUI AI guide for a replayed Honolulu drive. The route is simulated so the realtime voice demo is repeatable and does not require live driving."

10-25 seconds: Select `AI Guide`, tap `Replay`, and point out the moving route marker plus nearby context. "The app ranks bundled Honolulu facts near the current route position and keeps an audit trail of selection and cooldown decisions."

25-45 seconds: Let `gpt-realtime-2` speak one concise fact from the current compact context. "Realtime gets the route label, top ranked facts, cooldown state, and recent narration, not the whole data pack."

45-65 seconds: Press and hold the mic, or tap the canned interruption. "Now I interrupt with: skip food, give me the history angle, and keep it short. `gpt-realtime-2` pivots while the route replay keeps moving."

65-80 seconds: Point to the audit panel. "This is the context ledger: model transcript, user utterance, ranked candidates, distance/category reasons, cooldown decisions, and fallback status."

80-90 seconds: Close with the fallback. "If Wi-Fi or API access fails, the same route replay continues in Local Guide mode with AVFoundation speech, so the demo still works without live driving or turn-by-turn navigation."

## Application Materials

Short one-liner:

Cruisin is a native iOS realtime AI guide that uses `gpt-realtime-2` to narrate a simulated Honolulu drive from compact local route context, with an auditable Local Guide fallback.

Copy-pastable answer:

Project name: Cruisin AI Guide Mode

Repo: https://github.com/jskoiz/cruisin

Demo video or live demo link: pending external task. The local capture exists at `.derivedData/demo-artifacts/cruisin-ai-guide-demo-89s.mp4`, but no public upload/share link has been created yet.

Cruisin is a native SwiftUI iOS prototype for OpenAI Voice Hack Night. It replays a simulated Honolulu route, ranks bundled nearby facts, and sends compact route context to OpenAI Realtime with `gpt-realtime-2` so the guide can speak concise narration.

What I am building with OpenAI realtime models: AI Guide Mode, a spoken route guide that can respond to driver questions while the simulated drive continues. In the demo, push-to-talk can interrupt the guide with "Skip food. Give me the history angle, and keep it short," and `gpt-realtime-2` uses the current route context plus local preferences to answer briefly.

Relevant links: the public repo is https://github.com/jskoiz/cruisin. The demo video link is still an external upload/share task; the current local demo artifacts are under ignored `.derivedData/demo-artifacts/`.

Models used: OpenAI Realtime with `gpt-realtime-2`.

Scope and safety: the demo uses simulated route replay only. It is not live driving, not turn-by-turn navigation, not traffic-aware, not CarPlay, and not a backend or scraping system. If credentials, Wi-Fi, or API access fail, the same route replay continues in Local Guide mode with AVFoundation speech.

## Current Local Validation

Local route replay, AI Guide Mode, interruption, and AVFoundation fallback were visually validated from `/Users/jk/Desktop/cruisin` at commit `d188985` on May 20, 2026 HST / May 21, 2026 UTC:

- `git status --ignored -sb` showed a clean tracked tree with only ignored `.env` and `.derivedData/`.
- Secret scan excluding `.env`, `.env.local`, and `.derivedData/` found no committed OpenAI, AWS, Google, Slack, Linear, or private-key patterns.
- `xcodebuild -list -project Cruisin.xcodeproj` found target and scheme `Cruisin`.
- `xcodebuild -project Cruisin.xcodeproj -scheme Cruisin -configuration Debug -derivedDataPath .derivedData -destination 'generic/platform=iOS Simulator' build` succeeded.
- For this submission cleanup pass, Build iOS Apps/XcodeBuildMCP `build_sim` was rerun from `/Users/jk/Desktop/cruisin/Cruisin.xcodeproj` with scheme `Cruisin` on iPhone 17 Pro Max iOS 26.5 and succeeded.
- Build iOS Apps/XcodeBuildMCP built and launched `Cruisin` from `/Users/jk/Desktop/cruisin/Cruisin.xcodeproj` on iPhone 17 Pro Max iOS 26.5 with bundle `com.avmillabs.cruisin`.
- Local Guide visible flow: tapping `Start` moved the route from Waikiki toward Fort DeRussy, changed status to `Live replay`, showed `Speaking: Waikiki`, updated nearby candidates, and displayed cooldown/context audit rows.
- AI Guide visible flow: launching with `SIMCTL_CHILD_OPENAI_API_KEY` populated from ignored `.env`, selecting `AI Guide`, and tapping `Start` showed `GPT-Realtime-2 Connected`, then `GPT-Realtime-2 Speaking`, with a model transcript generated from the route context.
- Interruption visible flow: using AI Guide push-to-talk, or tapping the canned command, records `Skip food. Give me the history angle, and keep it short.` in the audit panel and updates context preferences toward history/quiet guidance.
- Fallback visible flow: relaunching without `OPENAI_API_KEY` showed `GPT-Realtime-2 Fallback`, reported the missing environment variable in the audit panel, and continued replay with `Local fallback: Waikiki`.

The merged submission state was revalidated from `/Users/jk/Desktop/cruisin` on May 20, 2026 HST / May 21, 2026 UTC:

- `xcodebuild -project Cruisin.xcodeproj -scheme Cruisin -configuration Debug -derivedDataPath .derivedData -destination 'generic/platform=iOS Simulator' build` succeeded.
- `xcodebuild -project Cruisin.xcodeproj -scheme Cruisin -configuration Debug -derivedDataPath .derivedData -destination 'generic/platform=iOS Simulator' test` correctly reported that XCTest requires a concrete simulator device.
- `xcodebuild -project Cruisin.xcodeproj -scheme Cruisin -configuration Debug -derivedDataPath .derivedData -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' test` succeeded with 5 logic tests.

The Kalakaua Avenue route update was revalidated from `/Users/jk/.codex/worktrees/7c5b/cruisin` on May 20, 2026 HST / May 21, 2026 UTC:

- Build iOS Apps/XcodeBuildMCP `test_sim` succeeded on iPhone 17 Pro Max iOS Simulator with 6 logic tests.
- Build iOS Apps/XcodeBuildMCP `build_run_sim` succeeded from this worktree and launched bundle `com.avmillabs.cruisin`.
- Visual check confirmed the closer street map, Route/Close/Street zoom control, recenter button, and a road-following Kalakaua Avenue replay starting at Ala Moana Boulevard toward Kapahulu Avenue.
- `python3 Scripts/package_voice_hack_night.py` succeeded and copied 2 videos plus 4 screenshots into ignored `dist/voice-hack-night/`.
- `(cd dist/voice-hack-night && shasum -a 256 -c CHECKSUMS.txt)` succeeded.

The push-to-talk demo simplification was revalidated from `/Users/jk/.codex/worktrees/7c5b/cruisin` on May 21, 2026 HST:

- Build iOS Apps/XcodeBuildMCP `build_sim` succeeded on iPhone 17 Pro Max iOS Simulator.
- Build iOS Apps/XcodeBuildMCP `test_sim` succeeded with 6 logic tests.
- Relaunching with `SIMCTL_CHILD_OPENAI_API_KEY` populated from ignored `.env`, selecting `AI Guide`, and tapping `Start` showed `GPT-Realtime-2 Speaking` while the mic stayed off at `Hold mic to talk`; no self-interruption was visible in the user utterance audit row.

Local demo artifacts, intentionally kept under ignored `.derivedData/`:

- `.derivedData/demo-artifacts/cruisin-ai-guide-demo-89s.mp4`
- `.derivedData/demo-artifacts/cruisin-ai-guide-demo.mp4` backup capture
- `.derivedData/demo-artifacts/local-guide-live-replay.jpg`
- `.derivedData/demo-artifacts/ai-guide-speaking.jpg`
- `.derivedData/demo-artifacts/ai-guide-interruption-audit.jpg`
- `.derivedData/demo-artifacts/fallback-no-openai-key.jpg`

Build the repeatable local submission pack after the video and screenshots exist:

```sh
python3 Scripts/package_voice_hack_night.py
```

The script rebuilds ignored `dist/voice-hack-night/`, copies only video and screenshot files from ignored `.derivedData/demo-artifacts/`, extracts this README's `Application Materials` section into `application-answers.md`, writes `manifest.json`, and writes SHA-256 hashes to `CHECKSUMS.txt`. It also verifies `.derivedData/`, `dist/`, `.env`, `.env.local`, and local secret config paths are protected by `.gitignore` before packaging.

Treat AI Guide Mode validation separately: launch with an ignored `OPENAI_API_KEY`, confirm `gpt-realtime-2` speaks from compact context, verify push-to-talk interruption behavior, then confirm Local Guide/AVFoundation fallback still works with the key removed.

## Risk And Fallback Notes

- Wi-Fi/API failure: continue the same replay in Local Guide mode and use AVFoundation narration.
- Missing or invalid `OPENAI_API_KEY`: do not block the demo; keep the key out of the repo and demonstrate the local fallback path.
- Realtime latency or push-to-talk interruption failure: narrate the currently selected local fact with AVFoundation and use the audit panel to explain what would have been sent to `gpt-realtime-2`.
- No live driving: route position is simulated from bundled waypoints for repeatable event demos.
- No turn-by-turn, traffic, or CarPlay: MapKit is used as a visual route replay surface only.
- No backend or runtime scraping: the app uses bundled Honolulu facts with source URLs.

## Unresolved External Tasks

- Upload or share `.derivedData/demo-artifacts/cruisin-ai-guide-demo-89s.mp4`, then replace the pending demo link.
- Run the final event dry run with a valid ignored `OPENAI_API_KEY` and the expected venue network; keep keys out of screenshots, logs, commits, and recordings.
- Submit the final OpenAI Voice Hack Night application using the repo link and uploaded demo video link.

## Next Best Step

Upload the 89-second demo video, paste the final share link into the application materials, and run one venue-network dry run with an ignored `OPENAI_API_KEY`.
