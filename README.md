# Cruisin

Native SwiftUI voice-guide prototype for Honolulu route replay.

Cruisin is currently an offline-first iOS MVP. The app launches directly into a driving screen with a MapKit map, simulated route position, nearby local facts, narration status, Start/Pause/Replay controls, and an audit panel showing why narration was or was not selected.

## Local Secrets

Copy `.env.example` to `.env` and fill only the providers used by the current prototype.

No secret is required for the current MVP. The app uses bundled JSON, MapKit, and local AVFoundation speech. Keep optional API keys in `.env` or another ignored local config file; do not add provider keys to Swift source, JSON resources, or project settings.

## Project Layout

- `Cruisin.xcodeproj`: single-target iOS app project.
- `Cruisin/`: SwiftUI app source plus bundled `HonoluluFacts.json` and `HonoluluRoute.json`.
- `Scripts/generate_honolulu_seed.py`: regenerates the offline Honolulu data pack.

## Data Pack

The generated seed pack currently contains 65 Honolulu-area facts/POIs and 28 replay route waypoints. Every fact has:

- stable `id` for dedupe,
- `name`, `category`, coordinates, and priority,
- short narration text,
- `sourceName` and `sourceURL` attribution.

Regenerate the bundled resources:

```sh
python3 Scripts/generate_honolulu_seed.py
```

The app does not fetch live data at runtime after these files exist in `Cruisin/`.

## Build And Run

Recommended simulator target used for validation:

```sh
xcodebuild \
  -project Cruisin.xcodeproj \
  -scheme Cruisin \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  build
```

To run interactively, open `Cruisin.xcodeproj` in Xcode and run the `Cruisin` scheme on an iOS simulator, or use the Build iOS Apps/XcodeBuildMCP simulator run workflow with:

- project: `/Users/jk/Desktop/cruisin/Cruisin.xcodeproj`
- scheme: `Cruisin`
- bundle id: `com.avmillabs.cruisin`

## Demo Script

1. Launch the app. The first screen is the driving surface, not a landing page.
2. Confirm the top panel shows `Honolulu Drive`, the current route label, and narration status.
3. Confirm the map shows the cyan Honolulu route, the current car marker, and nearby POI pins.
4. Tap `Route Replay` or `Start`.
5. Watch the car marker move from Waikiki toward Ala Moana, Kakaako, the civic core, Aloha Tower, and Chinatown.
6. Listen for short local narration. The engine uses cooldowns and spoken IDs so it does not talk constantly or repeat the same fact.
7. Open the audit panel if needed. It shows candidate facts, selection/cooldown reasoning, and the most recent spoken narration.

This gives a 2-3 minute walkthrough if you pause briefly at the major route areas and inspect the audit panel while replay continues.

## Current Validation

Validated in this checkout on May 20, 2026:

- `python3 Scripts/generate_honolulu_seed.py` wrote 65 facts and 28 route waypoints.
- `xcodebuild -list -project Cruisin.xcodeproj` found target and scheme `Cruisin`.
- Build iOS Apps/XcodeBuildMCP launched `Cruisin` on iPhone 17 Pro Max iOS 26.5 with bundle `com.avmillabs.cruisin`.
- Visible simulator flow: tapping `Start` moved the route position to `Ala Wai Harbor`, changed status to `Live replay`, showed nearby candidates, and displayed a spoken Waikiki narration event in the audit panel.

## Known Limitations

- Location is simulated through a CoreLocation-compatible route abstraction; live GPS following is not wired yet.
- The Honolulu facts are curated local seed data with source URLs, not a live crawler or search pipeline.
- Narration uses local `AVSpeechSynthesizer`; OpenAI Realtime voice is intentionally out of MVP scope until a real voice experience and key handling are justified.
- MapKit routing is visual replay only. There is no turn-by-turn navigation, traffic, background audio mode, or CarPlay support yet.

## Next Best Step

Add a small automated test target for narration selection and cooldown behavior, then add a switch between route replay and real `CLLocationManager` samples for on-device testing.
