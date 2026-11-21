#!/usr/bin/env python3
"""Review a recorded SightSense walk with Gemini, and get a tuning report.

    python3 Tools/review_walk.py path/to/Recordings/2026-11-21_14-03-10 [--keep]

1. Prepare (on this Mac): faces are blurred, the walk becomes walk.mp4, and a few frames are
   picked (Tools/prepare_walk.swift).
2. Agentic video understanding: Gemini 4 Hydrogen explores the video's timeline and lists every
   hazard a guide should mention, with times.
3. Managed Agent: a Gemini Managed Agent (Antigravity, in a fresh Google-hosted sandbox) gets the
   walk's logs, those frames, the video findings and Tools/summarize_walk.py. It compares what
   SightSense said with what was there, looks at the frames where they disagree, and writes
   report.md: missed hazards, needless announcements, timing, and which settings to change.
   The sandbox is deleted afterwards unless you pass --keep.

Output: <recording>/review/report.md and video_hazards.json.
The Gemini key comes from GEMINI_API_KEY or Config/Secrets.xcconfig. Standard library only.
"""
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://generativelanguage.googleapis.com"
VIDEO_MODEL = "gemini-4-hydrogen"
AGENT = "antigravity-preview-09-2026"
ROOT = Path(__file__).resolve().parent.parent

VIDEO_PROMPT = """\
This video was recorded by a phone worn on the chest of a blind person who is walking; the camera \
faces the way they face. List every moment a good sighted guide would mention: obstacles in or near \
the walking path (say what they are), steps, curbs or drop-offs, doors and exits, and people or \
vehicles coming toward them. Ignore decoration and anything well off the path.
Reply with JSON only: an array of objects with "time" (seconds from the start of the video), \
"what", "where" (ahead, slightly left, left, slightly right, right) and "urgency" ("urgent" if it \
needs a warning now, "useful" if worth mentioning, "minor" otherwise)."""

REVIEW_TASK = """\
You are reviewing one recorded walk of SightSense, an iPhone app worn on the chest that guides a \
blind person: it warns about obstacles, drop-offs and things approaching, and should stay quiet \
otherwise. Find the uploaded walk first (the directory that contains events.jsonl and \
frames.jsonl; for example `find / -name events.jsonl -path '*walk*' 2>/dev/null`).

In that walk directory:
- events.jsonl: everything the app announced (time in seconds, kind, urgent, text, latency in ms).
- frames.jsonl: every camera frame's time and sensor data; frames/: a selection of those frames
  (one every half second, and every frame within a second of an announcement), faces blurred.
- The script /workspace/tools/summarize_walk.py summarizes a walk: run it on the walk directory.

What a separate video model found in the whole walk (times in seconds from the first frame):
{hazards}

Do this, using code where it helps:
1. Run summarize_walk.py on the walk directory.
2. Match the app's announcements to the video findings (within about 2 seconds, same thing).
3. Look at the frames around every mismatch to decide what really happened: a hazard the app
   missed, an announcement that wasn't needed, or one that came too late.
4. Write the report, in plain English, to review/report.md next to the walk directory (that is,
   <walk directory>/../review/report.md). Sections: Summary (3 sentences), Numbers
   (announcements per minute, latency), Missed hazards, Needless or wrong announcements,
   Late warnings, Settings to change, Code to tune, and What to record next.
Then reply with the report's Summary section only.

The app's real settings (recommend only these, by these names, and only what each one controls):
- Announcements: essential (only things in the path you'll reach in a few seconds), balanced
  (also things just beside the path, and crowds), everything (anything nearby, once each).
  Safety warnings are spoken at every level.
- Announced categories: people, vehicles and bikes, furniture and obstacles, animals, signs and
  traffic lights; and whether to announce unnamed obstacles found by depth.
- Beeps: off, path (only for something in the path, only while walking), always.
- Alerts: brief or full wording; distances in steps or meters; camera height (chest height).
- Saved-people recognition: strict, balanced, relaxed. It only decides when a saved person is
  named; it has nothing to do with detecting people as obstacles.
Anything else (detector confidence, how many sightings confirm an object, depth calibration,
warning distances and timing) is code, not a setting: put it under Code to tune, as specific
as the evidence allows."""


def load_key() -> str:
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    secrets = ROOT / "Config" / "Secrets.xcconfig"
    if not key and secrets.exists():
        match = re.search(r"^GEMINI_API_KEY\s*=\s*(\S+)", secrets.read_text(), re.MULTILINE)
        key = match.group(1) if match else ""
    if not key:
        sys.exit("No Gemini key: set GEMINI_API_KEY or fill in Config/Secrets.xcconfig.")
    return key


KEY = ""


def call(method: str, path: str, body=None, *, data: bytes | None = None, headers=None,
         raw=False, ok=(200,), timeout=300):
    """One HTTP request to the Gemini API. Returns (parsed JSON or bytes, response headers, status)."""
    url = path if path.startswith("http") else API + path
    sent = {"x-goog-api-key": KEY, **(headers or {})}
    if body is not None:
        data = json.dumps(body).encode()
        sent["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=sent)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload, status, response_headers = response.read(), response.status, response.headers
    except urllib.error.HTTPError as error:
        payload, status, response_headers = error.read(), error.code, error.headers
    if status not in ok:
        detail = payload[:600].decode(errors="replace")
        sys.exit(f"{method} {url.split('?')[0]} failed: HTTP {status}\n{detail}")
    if raw:
        return payload, response_headers, status
    return (json.loads(payload) if payload.strip() else {}), response_headers, status


def output_text(interaction: dict) -> str:
    """The final answer of an interaction (model or agent)."""
    if interaction.get("output_text"):
        return interaction["output_text"]
    for step in reversed(interaction.get("steps", [])):
        if step.get("type") == "model_output":
            return "".join(part.get("text", "") for part in step.get("content", []) if part.get("type") == "text")
    return ""


def wait(interaction: dict, label: str) -> dict:
    """Polls a background interaction until it finishes, showing progress."""
    started, last_steps = time.time(), -1
    while interaction.get("status") == "in_progress":
        time.sleep(5)
        interaction, _, _ = call("GET", f"/v1beta/interactions/{interaction['id']}")
        steps = interaction.get("steps", [])
        if len(steps) != last_steps:
            last_steps = len(steps)
            kind = steps[-1].get("type", "") if steps else "starting"
            print(f"  {label}: {time.time() - started:4.0f} s, {len(steps)} steps (latest: {kind})")
    if interaction.get("status") not in (None, "completed"):
        sys.exit(f"{label} ended as {interaction.get('status')}: {json.dumps(interaction.get('error', ''))[:400]}")
    return interaction


# ---- 1. Prepare ----

def prepare(recording: Path, review: Path) -> None:
    print("1/3 Preparing the walk (blurring faces, making the video)…")
    result = subprocess.run(["xcrun", "swift", "-suppress-warnings", str(ROOT / "Tools" / "prepare_walk.swift"),
                             str(recording), str(review)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"Preparing failed:\n{result.stderr.strip()}")
    print("   " + result.stdout.strip())


# ---- 2. Agentic video understanding ----

def find_hazards(video: Path) -> list:
    print("2/3 Agentic video understanding: finding hazards in the video…")
    size = video.stat().st_size
    _, headers, _ = call("POST", "/upload/v1beta/files", {"file": {"display_name": "sightsense-walk"}}, headers={
        "X-Goog-Upload-Protocol": "resumable", "X-Goog-Upload-Command": "start",
        "X-Goog-Upload-Header-Content-Length": str(size), "X-Goog-Upload-Header-Content-Type": "video/mp4"})
    info, _, _ = call("POST", headers["X-Goog-Upload-URL"], data=video.read_bytes(), headers={
        "Content-Length": str(size), "X-Goog-Upload-Offset": "0", "X-Goog-Upload-Command": "upload, finalize"})
    file = info["file"]
    while file.get("state") == "PROCESSING":
        time.sleep(3)
        file, _, _ = call("GET", f"/v1beta/{file['name']}")
    if file.get("state") == "FAILED":
        sys.exit("Gemini couldn't process the video.")
    try:
        interaction, _, _ = call("POST", "/v1beta/interactions", {
            "model": VIDEO_MODEL,
            "input": [{"type": "video", "uri": file["uri"], "mime_type": "video/mp4", "processing": "agentic"},
                      {"type": "text", "text": VIDEO_PROMPT}],
            "background": True,
        })
        interaction = wait(interaction, "video")
    finally:
        call("DELETE", f"/v1beta/{file['name']}", ok=(200, 204, 404))  # don't leave the footage behind
    explored = sum(step.get("type") == "processing_call" for step in interaction.get("steps", []))
    text = output_text(interaction)
    match = re.search(r"\[.*\]", text, re.DOTALL)
    hazards = json.loads(match.group(0)) if match else []
    print(f"   {len(hazards)} hazards found; the model explored the timeline {explored} times (agentic mode).")
    return hazards


# ---- 3. Managed Agent ----

def review_with_agent(upload: Path, hazards: list, keep: bool) -> tuple[str, str]:
    print("3/3 Managed Agent: reviewing the walk in a Google-hosted sandbox…")
    script = (ROOT / "Tools" / "summarize_walk.py").read_text()
    setup, _, _ = call("POST", "/v1beta/interactions", {
        "agent": AGENT,
        "input": [{"type": "text", "text": "Reply with the single word: ready."}],
        "environment": {"type": "remote", "sources": [
            {"type": "inline", "target": "/workspace/tools/summarize_walk.py", "content": script}]},
        "tools": [{"type": "code_execution"}],
    })
    environment = setup["environment_id"]
    print(f"   Sandbox {environment} is ready.")
    try:
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as tar:
            tar.add(upload, arcname=".")
        call("PUT", f"/upload/v1beta/environments/{environment}/files/workspace/walk/?extract=true&overwrite=true",
             data=archive.getvalue(), headers={"Content-Type": "application/gzip"})
        print(f"   Uploaded the walk ({len(archive.getvalue()) / 1e6:.1f} MB).")

        listed = json.dumps(hazards, indent=1) if hazards else "(nothing)"
        interaction, _, _ = call("POST", "/v1beta/interactions", {
            "agent": AGENT,
            "previous_interaction_id": setup["id"],
            "environment": environment,
            "input": [{"type": "text", "text": REVIEW_TASK.replace("{hazards}", listed)}],
            "tools": [{"type": "code_execution"}],
            "background": True,
        })
        interaction = wait(interaction, "agent")
        summary = output_text(interaction)
        report, _, status = call("GET", f"/v1beta/environments/{environment}/files/workspace/review/report.md?alt=media",
                                 raw=True, ok=(200, 404))
        return summary, report.decode(errors="replace") if status == 200 else ""
    finally:
        if keep:
            print(f"   Kept the sandbox: {environment} (deleted automatically after 7 days).")
        else:
            call("DELETE", f"/v1beta/environments/{environment}", ok=(200, 204, 404))
            print("   Deleted the sandbox and the uploaded walk.")


def main() -> None:
    global KEY
    paths = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    if len(paths) != 1:
        sys.exit(__doc__)
    recording = Path(paths[0]).resolve()
    if not (recording / "frames.jsonl").exists():
        sys.exit(f"Not a SightSense recording (no frames.jsonl): {recording}")
    KEY = load_key()
    review = recording / "review"

    prepare(recording, review)
    hazards = find_hazards(review / "walk.mp4")
    (review / "video_hazards.json").write_text(json.dumps(hazards, indent=2))
    summary, report = review_with_agent(review / "upload", hazards, keep="--keep" in sys.argv)
    (review / "report.md").write_text(report or f"# Walk review\n\n{summary}\n")
    print(f"\nReport: {review / 'report.md'}\n\n{summary.strip()}")


if __name__ == "__main__":
    main()
