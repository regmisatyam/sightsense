# SightSense

A navigation aid for blind and low-vision users. The phone is worn upright on the chest,
back camera facing forward; everything comes out as sound, buzzes, and short spoken phrases.

**SightSense is a companion to a white cane or guide dog, not a replacement.** It can miss things.

## Setup

1. Open `SightSense.xcodeproj` and run on an iPhone (iOS 18+). Both models are included:
   - `Models/Detector.mlmodel`: Apple's YOLOv3 Tiny (80 everyday object classes; Darknet license).
   - `Models/Depth.mlpackage`: Apple's Core ML Depth Anything V2 Small, 8-bit (Apache-2.0).
2. Optional, for Describe and Calm Mode: `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig`
   and add a Gemini key, or the host of your own proxy (`server/gemini-proxy.js`) so the key never
   ships in the app. `Secrets.xcconfig` is gitignored.
3. On first launch, a spoken tutorial plays. Then open **Settings** (middle bar) and set your
   **camera height**: floor to where the phone sits. Every distance depends on it.
4. Headphones, ideally bone-conduction, give left/right beeps and the 3D place beacon.

## Using it

The screen is laid out to be used by feel. You only need to know which way is up:

```
┌─────────────────┐
│    DESCRIBE     │  top band
├─────────────────┤
│     ASK 🎤      │  middle band (turns red while listening)
├─────────────────┤
│      READ       │  bottom band
├─────┬─────┬─────┤
│MODE │BEEPS│MORE │  left corner · middle · right corner
└─────┴─────┴─────┘
```

| Do this | Screen | Phone on your chest (no screen) |
|---|---|---|
| Describe the scene | Tap the top band | **Volume up** |
| Ask a question or say a command | Tap the middle band | **Volume down**, or click your **AirPods** (iOS 26, H2 AirPods): press once and speak, or hold while you talk |
| Read / translate text (guided aiming) | Tap the bottom band (tap again to stop) | Say "read this" |
| Navigation → Calm → Live | Mode button (bottom-left corner) | Say "calm mode" / "live mode" / "navigation mode" |
| Quick questions (test without speaking) | Press and hold the Ask band | — |
| Be guided to the way out | Say "show me the way out" (or "take me to the door") | Same, by voice |
| Beeps on / off | Beeps button (bottom middle) | Say "beeps off" / "beeps on" |
| Places, settings, help, tutorial | More button (bottom-right corner) | Say "where am I", "help" |
| Stop talking | Press and hold anywhere | Say "stop" |
| What's ahead / around me | Swipe up / down | Say "what's ahead" / "what's around me" |
| Fewer / more announcements | Swipe left / right | Say "fewer" / "more" |

With VoiceOver, direct touch is on by default, so the same taps and swipes work. Two-finger double-tap
(Magic Tap) asks, and everything else is in the Actions rotor. Taps act instantly.

**The agent: one AI, one voice.** SightSense runs one Gemini Live conversation the whole time it's
open (`gemini-3.8-live`, falling back to `gemini-3.1-flash-live-preview`). This agent (`Agent/`):
- **sees** through the camera (one frame a second, which is what Gemini Live looks at; faces blurred);
- **hears** you when you tap Ask (it answers about 0.7 s after you stop talking), or all the time in
  **Live mode** (tap Ask to mute). It never hears itself: with earphones its voice doesn't reach the
  mic (and you can talk over it); on the phone's speaker the mic pauses while it talks;
- **is the app's only voice.** Everything SightSense says (hazard alerts, guidance, reading, Calm
  Mode, the tutorial) is handed to the agent as exact words ("[APP] SAY: …"), so it all comes in the
  same natural voice: measured word for word, about 0.5 s to the first sound. An alert cuts off
  whatever it was saying (~0.7 s);
- **acts through tools** (`Agent/AgentTools.swift`): measured distances (`get_obstacles`), `find`,
  `guide_to` (e.g. the way out), `read_text`, `look_closely` (the slower Neon model), `where_am_i`,
  `nearby_places`, and changing modes, beeps and announcements. Slow tools answer "started" at
  once and report later, because Gemini Live holds back everything, even an alert, while a tool
  call is unanswered (measured: a 5 s tool delayed an alert by 5 s).

There is no second, robotic voice. Obstacles are detected on the phone, and warnings sound and buzz
first, so they work without the network. If the agent can't be reached you hear two low notes
("uh-oh"): warnings keep sounding and buzzing but without words, and the app reconnects every 20 s
("The AI is back."). A warning that hasn't started within 3 s is dropped rather than said late.

**Saved people:** say (or pick from quick questions) "save the person in front of me as Alex". The
agent calls `remember_person`; the phone takes about 8 views of the face in 3 seconds and stores them as
numeric signatures (Vision feature prints of tight grayscale face crops), never photos. From then on, a
three-note chime and "Alex is in view, slightly left, 3 steps" when Alex appears (at most once every
2 minutes). "Who's here?" and "forget Alex" work too; Settings › People lists everyone with a Forget
button, and has Strict / Balanced / Relaxed recognition.
- Privacy: recognition runs only on the phone; faces stay blurred in what Gemini sees; signatures are
  excluded from backups; only people the user saved are ever named, never strangers. Ask people first.
- Honest limits: iOS has no public face-recognition API and no third-party model is used, so this
  matches general image signatures. Measured scale on this setup: a slightly shifted crop of the same
  thing ≈ 0.22 apart, different things ≈ 0.9–1.2; faces of different people land in between, so a
  match needs to be within the person's own variation (×1.6, kept between 0.32 and 0.5), clearly
  better than anyone else saved, and seen in 2 of 3 scans. Not yet measured on real faces: watch the
  scores in the laptop viewer (pink boxes, "score / limit") and pick the strictness that fits.

**Show me the way out:** the spatial model (Robotics-ER) keeps re-finding the exit door, exit
sign or doorway as you move (about every 2 s). The 3D beacon sound points at it, and short updates
tell you which way and how far ("Exit door, left, 8 steps") until you arrive ("You're at the
exit door") or say stop. Obstacle warnings keep running and take priority.

**Voice:** pick the agent's voice in Settings › What the AI says; the speaking speed slider sets
its pace (relaxed, natural, brisk). With earphones connected (wired or Bluetooth), everything plays
through them in full stereo (the 3D beacon needs it) and the phone's own mic, on your chest, listens.
The microphone indicator stays on while the agent is connected, because it listens the moment you tap Ask.

**Asking:** with the agent connected, anything you say or pick from the quick questions goes to it,
and it decides what to do. Offline, short familiar phrases ("where am I", "read this", "beeps off",
"help") are recognized on the phone, and other questions go to the REST models with the photo.

While SightSense is open, the volume buttons control it (Settings can turn this off). Change the
volume in Control Center or on your headphones.

**Walking or standing** is detected from footsteps (the regular bounce of each step, plus GPS
speed), not just any movement. Proximity beeps play only while you walk and stop about 2.5 s after
you stand still. Handling the phone or swaying doesn't count as walking.

### What you'll hear

- **Close obstacle in your path:** double beep + two buzzes + "Stop. Chair, ahead, 1 step."
- **Something unnamed in your path** (pole, wall, bin): "Obstacle ahead, 3 steps."
- **The ground drops** (stairs down, curb, hole): falling tone + three slow buzzes + "Drop ahead, 2 steps."
- **Something approaching fast:** rising tone + three quick buzzes + "Bicycle approaching, right."
- **Crowds** are grouped: "4 people ahead."
- **Proximity beeps** point toward the nearest thing in your way and speed up as it gets closer.
### Only what matters right now

SightSense filters its own speech:
- **Standing still**, your surroundings aren't news: only safety alerts are spoken (drop-offs,
  something coming at you fast, something right against you, said once).
- **Walking**, it mentions things in your path that you'll reach in the next few seconds.
- **Each thing is said once.** It's remembered by what it is and where it is in the world (using the
  compass), so the detector losing and re-finding it, or you turning, doesn't make it new.
  It's repeated only when it becomes urgent.
- Non-urgent alerts are at least 5 s apart. Calm Mode speaks only when the scene changed
  (you walked on, turned, or different things are around), at most as often as you choose.

**You control it** (Settings › What to announce, or swipe left/right):
- *Only what's in my way* (default) · *Also things beside me* (adds crowds) · *Everything nearby*.
- Switch groups on or off: people, vehicles and bikes, furniture and obstacles, animals,
  signs and traffic lights, unnamed obstacles, places you walk past.
- Beeps: off, for your path while walking (default), or always.
- **What the AI says** (Settings › What the AI says): Describe focuses on your path, the place,
  signs and text, people, or **your own instruction** (for example "tell me shop names and where
  the doors are"), short or longer.

Safety alerts can't be switched off.

## How it works

**Fast loop, on the phone, no network** (`App/FastLoop.swift`):
- `Capture/`: 0.5× ultra-wide camera at 15 fps, so the floor is visible about 1 m ahead instead of about 2 m.
  Each frame carries the real lens angles, the phone's tilt, the wearer's movement, and which way they face.
- **Named objects:** `Perception/ObstacleDetector` (YOLO every 2nd frame; Vision's people and pet
  detectors if no model) → `Tracker` (smoothed, predicts motion, confirms after 3 sightings or 2 if
  close; measures how fast each object grows for time-to-collision) → `Reasoning/DistanceEstimator`
  (object size + where it meets the floor) → `HazardPrioritizer`.
- **Anything in the path:** `Perception/DepthEstimator` (depth model every 4th frame) →
  `Reasoning/PathScanner`, which calibrates monocular depth against the floor each pass (anchored
  on the floor nearest your feet) and finds anything rising out of the floor within your walking
  corridor, plus drop-offs → `PathConfirmer` (3 of the last 4 scans must agree).
- `Reasoning/AlertPlanner` decides what to say, in safety order → `Output/AlertPresenter`:
  sound and buzz first, then words.
- Standing still or a hot phone halves the scanning rate. The screen dims to save battery.

**Cloud (optional), several Gemini models, each matched to its job** (`Reasoning/GeminiModels.swift`):

| Job | Model | Measured (time to first words, streaming) |
|---|---|---|
| Describe, Instant Describe, Calm Mode text | **Gemini 4 Carbon** | 3.3–4.5 s, found chair *and* exit every time |
| Questions, longer descriptions, reading hard text | **Gemini 4 Hydrogen** | ~3.9 s, most practical advice |
| "Look carefully, …" questions | **Gemini 4 Neon** | 7–21 s, thinks hardest |
| Find / way-out guidance: points at it in the photo | `gemini-robotics-er-2-preview` | ~2.3 s |
| The agent: conversation, tools, and every spoken word | `gemini-3.8-live` | ~0.5 s to first sound |

Chosen by benchmark on a corridor scene (chair in the path, exit door on the left). The previous
quick-look model, Flash-Lite, answered faster (1.2–1.8 s) but missed the exit door every time.
The Gemini 4 models are undocumented codenames, so each job falls back to a proven 3.x model
(Flash-Lite, Flash, Pro). Gemini 4 doesn't do Live, so the agent stays on 3.x.
Every job has a fallback model, and a model that rejects a setting is retried without it.
Override any model in `Config/Secrets.xcconfig` (`GEMINI_MODEL_FAST`, `_SMART`, `_DEEP`, `_SPATIAL`, `_LIVE`).
Usage isn't capped. **Instant Describe** (only while the agent is offline) keeps a fresh
description ready (every 8 s walking, 20 s standing) so Describe answers immediately. **Find** turns the model's point into a direction,
gets the distance from depth, and guides you there with the 3D beacon for 45 s. If the thing
isn't in view, the question goes to the AI with nearby places. If the phone can't read some
text, Read hands it to the AI. Photos are sent with faces pixelated, along with the phone's own
measurements, so answers use the same directions and distances as the alerts. Answers stream
sentence by sentence, and any sentence claiming the way is clear or safe is dropped.

**Read:** `Modes/TextReader` coaches you onto the text ("Text continues above. Tilt up a
little.") using `Reasoning/AimingCoach`, reads it when steady, and translates on the phone with
Apple Translation when it isn't in your language.

**Places (Soundscape-style)** (`Explore/`). Microsoft Soundscape was discontinued in 2023. Its core
ideas are rebuilt here natively, with Apple Maps and no extra keys or packages:
- Where am I: street, area, which way you face, nearest place.
- Around me: the nearest place in each direction. Ahead of me: places in front of you.
- Callouts as you walk past places, at low priority so hazards always come first.
- An audio beacon: a 3D ping from the place's direction that turns brighter when you face it,
  with progress updates and an arrival notice.
- Which way you face comes from the camera direction (gravity + magnetometer, corrected to true
  north), because a phone worn upright confuses a normal compass reading.

## Measuring and tuning

- **Tests:** ⌘U in Xcode (or `xcodebuild test`). The 96 tests check geometry against synthetic scenes
  with known answers: distances, the walking corridor, poles, stairs going down, depth
  calibration, tracker identity and approach speed, what gets said and when (including noise
  filtering: walking toward a chair, detector flicker, turning, standing at a table), Calm Mode
  change detection, walking vs standing from footsteps, voice commands, which Gemini model does
  which job, reading Find's points, the agent's Live API messages and tools, way-out guidance, audio
  decoding, aiming hints, the safety filter, compass math, saved-people matching and announcements, and the laptop viewer (its drawn distances
  match the app's own measurements; its server and messages).
- **Debug overlay** (Debug builds): fps, detection and depth time, tilt, honest latency
  (first seen → sound, median and 95th percentile), and each object's meters and angle.
- **Laptop viewer** (`Debug/Viewer/`): Settings › Testing › Laptop viewer, then open the address shown
  there (e.g. `http://192.168.1.23:8080`) in any browser on a laptop on the same Wi-Fi or the phone's
  hotspot. CCTV-style: the live camera (faces blurred, ~8 fps) with distance rings (1, 2, 3, 5 m),
  the walking lane (±0.45 m) and the horizon drawn on the floor using the same ray math the app
  measures with; each object's box, distance and floor coordinates (x right, z ahead, in meters);
  obstacle and drop-off marks; and a target on what Find or guidance last pointed at. Four corners:
  the agent (heard, said, tools), everything said (and what couldn't be said while the AI was offline), on-phone
  perception (fps, timings, walking, noise held back, objects), and REST model calls with guidance.
  Space freezes the picture, G hides the drawing. Nothing is encoded or sent while no laptop is watching.
- **Record real walks:** Settings › Record walks. Copy a recording off the phone, then:
  - `python3 Tools/summarize_walk.py <folder>` gives alerts per minute and latency;
  - the launch argument `-replay <folder>` (in the scheme, disabled by default) replays it through the whole app.

## Known limits

- Monocular depth is approximate. It has only been checked against synthetic scenes here,
  not measured outdoors. Record walks and compare against a tape measure before relying on distances.
- Drop-off detection needs floor visible close to your feet: use the wide lens.
  Glass, very dark scenes, and thin overhanging objects remain hard.
- iOS stops the camera when the phone locks. SightSense says "paused" when that happens; consider
  Guided Access to prevent accidental locking.
- Spoken phrases are English (an English voice is used on other-language phones). Proper
  localization needs translated strings.
- Place data and descriptions need a network; obstacle warnings never do.
