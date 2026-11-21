Project: "SightSense", an app navigation aid for blind
and low-vision users. Phone worn on the chest, camera facing forward. Voice output only.

Core idea: two loops.
- Fast loop (on-device, <200ms): detect obstacles, estimate distance,
  warn with speech + directional beeps. Never depends on network.
- Slow loop (cloud): Gemini describes the scene on request, and
  "Calm Mode" narrates surroundings in a calm, warm, lightly funny voice
  ONLY when no hazard is near. Hazard alerts always interrupt.
Plus: read and translate text (Vision OCR + Apple Translation framework).

Architecture (one folder each):
App/ Capture/ Perception/ Reasoning/ Output/ Modes/ Debug/
- protocol FrameSource { start(); stop(); frames: AsyncStream<CVPixelBuffer> }
  PhoneCameraSource implements it (AVCaptureSession, 640x480, ~15fps).
  Design so a Meta glasses source can be added later with no other changes.
- ObstacleDetector: VNCoreMLRequest using a model at Models/Detector.mlmodel
  (I will add it). Run every 2nd-3rd frame.
- Tracker: IoU matching, report an object only after 3 consecutive frames.
- DistanceEstimator: box height + typical real height per class → near/mid/far.
- HazardPrioritizer: score = class weight × closeness × centrality;
  3s cooldown per tracked object.
- SpeechQueue: AVSpeechSynthesizer with priorities; urgent alerts
  call stopSpeaking(at: .immediate).
- SpatialAudio: AVAudioEngine + AVAudioEnvironmentNode, pan by box x,
  beep rate by distance.
- SceneDescriber: Gemini API, downscaled JPEG, max 1 call / 5s,
  API key from Secrets.xcconfig (gitignored). Graceful offline fallback.
- UI: two large tap zones (top = Describe, bottom = Read), double-tap
  switches modes, full VoiceOver labels, screen kept awake.
- Debug overlay: boxes, FPS, frame→audio latency in ms.

Time budget: 5 hours total. Phases:
P0 skeleton+speech (45m), P1 detection (75m, no full tracker:
same class in 3 consecutive frames), P2 distance + priority + stereo
pan beeps via AVAudioPlayerNode.pan (60m), P3 OCR + Apple Translation
(60m), P4 accessibility polish (30m). Prefer the simplest working
version. Stop after each phase so I can test on device.

Rules:
- Work in phases; stop after each so I can run it on device:
  P0 skeleton + speech, P1 detection, P2 hazards, P3 spatial audio,
  P4 read/translate, P5 Gemini + Calm Mode, P6 accessibility polish.
- After each phase, summarize changes and suggest a git tag (v0-skeleton…).
- Small, readable files. No third-party packages unless you ask me first.
- Never commit secrets.

Start with Phase 0 only.