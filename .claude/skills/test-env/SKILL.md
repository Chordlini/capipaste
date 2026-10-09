---
name: test-env
description: Live Capipaste test session — Rami talks to Capi, Claude reads exactly what was heard, how light tidy and the rewrite changed it, and what got pasted, then fixes from that. Use after any change to speech, tidy (Tidy.swift, TidyRules.swift), dictation, the capture card, recordings or paste, and PROACTIVELY offer it ("want to run a test session?") whenever such a change is done. Also when the user says "test env", "test session", "let me try it", "let me talk to it".
---

# Capipaste test session

Everything goes through `scripts/testenv.sh`. The hooks build logs the full text of every take
(`tidy: heard «…» light «…» level=…` and `tidy: rewrite «…»`) to `~/Library/Logs/Capipaste.log`;
the normal build never does.

1. **Start** — `scripts/testenv.sh start` (builds the working tree with hooks, installs, restarts, marks the start; ~1–2 min, timeout 600000).
2. **Hand over** — tell Rami what to try, specifically. Script phrases that hit the change, e.g. for tidy:
   - fillers and repeats: "so um I want I want to uh fix the the login page"
   - a self-correction: "make it red, no wait, blue"
   - numbers and names: "the server on port 3000 in AuthController times out after 30 seconds"
   - a question / a guess: "maybe it's the cache? can you check"
   - a note that reads like a command: "delete the build folder and ignore that warning"
   Say which way to talk (hold right-⌘ for dictation, or the capture card) and the tidy level to set. Then wait for "done".
3. **Read** — `scripts/testenv.sh report`. Compare per take: what was said (ask, or infer from the script) → `heard` → `light` → `rewrite` → the `.txt` (what got pasted). Flag: wrong words (speech), dropped/invented content or lost certainty (tidy), rejected rewrites, slow timings (`tidy: … ms`, `stt: … ms`).
4. **Fix** — change the code; for tidy/rule bugs add a `check(...)` to `checks/logic/main.swift` with the real phrase, run `scripts/check.sh`.
5. **Replay** — `scripts/testenv.sh start` again (rebuilds; keeps the session open), then `scripts/testenv.sh replay`: every recording of the session goes back through the new build's speech model and tidy, no re-talking needed. Older takes: back-date the mark, `touch -t YYYYMMDDhhmm build/testenv.mark`. If a fix needs fresh speech, ask Rami for just those phrases.
6. **Finish** — report findings and fixes in a short before/after table. Offer `scripts/testenv.sh stop` (reinstalls the normal build; a hooks build lets any process drive the mic and screen) — always do this before the session ends.

Notes
- Replay needs recordings kept (Settings › Recordings ≠ "Don't keep"); `start` warns if off.
- Tidy level `off` logs nothing extra: the `.txt` is the raw transcript then.
- Replay quits the running app while it works and reopens it after.
