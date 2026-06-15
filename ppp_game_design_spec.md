# Proper Paws Project — In-App Game Design Spec
> Maps to ppp_30day_framework.md. Each day's game mechanic is defined here with UI behavior, scoring logic, and difficulty progression.

---

## Core Design Philosophy

The app corrects the human so the trainer doesn't have to. Feedback is delivered by the game, not by a person. The handler experiences failure as a score, not as judgment. This removes social friction and guilt from the correction loop.

**The dog on screen is a surrogate dog.** It behaves unpredictably — just like a real dog — and the handler must react in real time. The game doesn't wait for them.

---

## Shared UI Components (Used Across All Games)

### The Dog Display
- Animated dog image (or sprite) rendered on screen
- Dog cycles through behaviors/positions based on the current game's behavior set
- Transitions are randomized in timing (not metronomic) to prevent pattern anticipation

### The Click Button
- Large, thumb-accessible button
- Labeled: **MARK** (or clicker icon)
- Records timestamp of press relative to dog behavior state
- Gives haptic feedback on press

### The Pay Button
- Separate button from the click, slightly smaller
- Labeled: **REWARD**
- Must be pressed after MARK — cannot be pressed first
- Records time delta between MARK and REWARD press

### The Score Display
- Shows current session stats: clean reps, late clicks, early clicks, missed reps
- Updates live during session

### Session End Screen
- Summary: total reps, clean %, timing average, gate status
- Pass/fail on gate criteria with plain-language explanation
- No shame language. Neutral, factual. "Your average mark was 0.6 seconds after the behavior. Target is under 0.3 seconds."

---

## Game Mechanics by Day

---

### Days 1–10 — Phase 1: Food Drive Restoration
**No in-app game during this phase.**

The protocol is entirely real-world. The app serves as a logging tool only:
- Handler records meal outcome (ate / refused)
- Handler logs day number in streak
- App enforces the gate before unlocking the next day
- Simple input form: bowl down? (Y/N) → timer ran? (Y/N) → outcome (ate all / ate some / refused)
- Streak counter visible on home screen
- If refused: app displays 24-hour reset message, does not unlock next day until 24 hours have elapsed

**UI note:** Keep this phase minimal. The handler is stressed enough. No gamification here — clean, clinical, supportive.

---

### Day 11 — The Clicker Game: Load
**First active game in the app.**

**Concept:** Dog on screen randomly selects from 6 pre-generated static positions. Handler must click MARK when the dog *settles into* a new position (not during the transition). Then press REWARD.

**Dog behavior set (6 positions):**
1. Sit
2. Down
3. Stand
4. Head turn left
5. Head turn right
6. Look up at handler

**Transition logic:**
- Dog holds each position for a randomized duration (2–5 seconds)
- Transition animation plays (~0.5 seconds)
- Dog settles into new position
- Handler window opens on settle

**Scoring:**
- **Clean rep:** MARK pressed within 0.3 seconds of settle → REWARD pressed within 2 seconds of MARK
- **Late mark:** MARK pressed 0.3–1.0 seconds after settle → counts as rep but flagged
- **Early mark:** MARK pressed during transition → does not count, flagged as "clicked the movement not the moment"
- **Missed:** No MARK pressed before next transition → missed rep
- **Slow pay:** REWARD pressed more than 3 seconds after MARK → flagged

**Session structure:**
- 30 reps per session
- Two sessions per day (morning + evening, or handler-initiated)
- Session ends automatically after 30 reps

**Gate:** 40+ clean reps across both sessions combined (out of 60 total). Unlocks Day 12.

**Feedback language examples:**
- Early click: "You clicked the movement. Wait for the moment the dog settles."
- Late click: "A little slow. The moment is right when they land, not after they've been there a while."
- Slow pay: "Pay faster after the mark. The dog connects the click to the reward — the gap matters."

---

### Day 12 — The Clicker Game: Cold Test
**Same mechanics as Day 11 with one addition.**

**Changes from Day 11:**
- Positions now include micro-movements within position (dog blinks, ear flick, small head shift) — handler must NOT click these, only the position settle
- At end of session 2: **Cold Test sequence** plays automatically
  - Dog wanders on screen doing nothing
  - A click sound plays from the app (no button press required)
  - Dog's reaction is animated: snaps to attention, looks at screen
  - Handler is prompted: "Did your real dog react like this?" → Yes / Not yet
  - Yes = gate condition met on this criterion
  - Not yet = app adds one more session before gate check

**Gate:** 40+ clean reps + cold test self-report passed.

---

### Day 13 — The Click Game: Eye Contact
**New behavior added to the dog's set.**

**Concept:** Dog on screen now randomly offers an "eye contact" moment — looks directly at camera/handler — mixed in with the 6 position changes. Handler must MARK the eye contact specifically, not just any position change.

**Dog behavior set:** Same 6 positions + **eye contact event** (dog looks directly forward, holds for 0.5–1.5 seconds)

**New scoring rule:**
- MARK on eye contact = clean rep
- MARK on position change = flagged ("You marked the position, not the engagement. Watch for the eyes coming up.")
- Missed eye contact = missed rep

**Difficulty:** Eye contact events occur randomly, ~every 4–6 position changes. Handler can't predict when it's coming.

**Gate:** 10+ clean eye contact marks across the session. Unlocks Day 14.

---

### Day 14 — The Click Game: Eye Contact Duration
**Same as Day 13 with duration added.**

**Change:** Eye contact event now holds for a randomized 1–3 seconds. Handler must MARK after the eye contact has been held for at least 1 second — not the instant it begins.

**Scoring:**
- MARK at 0–0.5 seconds into eye contact = too early, flagged ("Wait for them to commit to the look.")
- MARK at 0.5–2 seconds = clean
- MARK after eye contact breaks = late, flagged

**Gate:** 10+ clean duration marks.

---

### Days 15–16 — The Shape Game: Sit
**Mechanic shift: handler now decides what to click, not just when.**

**Concept:** Dog on screen moves freely — wanders, sniffs, changes positions randomly. Handler must identify when the dog is moving *toward* a sit and MARK the approximation. The game rewards criteria selection, not just timing.

**Dog behavior set (free movement):**
- Wander
- Sniff ground
- Look around
- Weight shift backward (approximation toward sit)
- Partial sit (butt lowering)
- Full sit
- Stand back up

**Scoring:**
- MARK on full sit = clean rep (highest value)
- MARK on partial sit = acceptable rep (flagged as "good, but you can wait for cleaner")
- MARK on weight shift = shaping rep (acceptable in early session)
- MARK on anything else = wrong criteria, flagged
- No MARK when sit offered = missed opportunity

**Difficulty progression Day 15 → 16:**
- Day 15: Dog offers sit frequently (~every 8–12 seconds)
- Day 16: Dog offers sit less frequently, more wandering between offers. Handler must wait longer without clicking non-sit behaviors.

**Gate:** 10+ clean or acceptable reps per session.

---

### Day 17 — The Shape Game: Down
**Same mechanic as Days 15–16, new target behavior.**

**Dog behavior set adds:**
- Weight shift forward
- Elbows lowering
- Full down
- Pop back up

**Handler must now NOT click sits** — only down approximations and full downs.

**Gate:** 10+ clean down reps.

---

### Day 18 — The Shape Game: Place
**Chained behavior — handler shapes a sequence, not a single moment.**

**Concept:** A raised cot appears on screen. Dog wanders. Handler must click successive approximations toward the cot: look at it → approach → front paws on → all four paws on.

**Scoring:**
- Each step in the chain clicked in order = chain rep
- Clicking out of order or clicking the wrong behavior = flagged
- Final behavior (all four paws on) = jackpot animation + max score

**Difficulty:** Dog may step off the cot and wander again, requiring the handler to re-shape from whatever step the dog is at.

**Gate:** 5+ complete chain reps (look → approach → front paws → all four paws).

---

### Day 19 — The Shape Game: Duration
**Place with hold added.**

**Change:** After dog loads onto cot on screen, a timer counts up. Handler must NOT click immediately — they must wait until the timer reaches the target duration before clicking.

**Duration targets:**
- Session 1: 5-second hold target
- Session 2: 15-second hold target

**Scoring:**
- Click before target duration = too early, flagged
- Click within 2 seconds of target = clean
- Click well after target = late, flagged (but still counts)

**Gate:** 5+ clean duration reps at 15-second target.

---

### Day 20 — The Shape Game: Mix
**All three behaviors in one session.**

**Dog on screen** randomly offers sit, down, or place approach. Handler must click the correct behavior regardless of which one appears.

**Scoring:**
- Correct behavior clicked = clean rep
- Wrong behavior clicked (click a sit when dog offers a down) = wrong criteria, flagged
- Missed = missed

**Gate:** 12/15 correct criteria selections across a 15-trial session.

---

### Days 21–22 — The Cue Game
**Verbal cue response testing.**

**Concept:** App displays a cue word on screen (SIT / DOWN / PLACE). Dog on screen does one of three things:
1. Performs the correct behavior (handler clicks MARK → REWARD)
2. Performs a different behavior (handler does NOT click — waits)
3. Offers nothing (handler does NOT click)

**Handler task:** Only click when the dog on screen performs the behavior that matches the displayed cue.

**Day 21:** One cue word only (first position). Dog responds correctly ~70% of trials.
**Day 22:** All three cue words, randomized. Dog responds correctly ~70% per cue.

**Scoring:**
- Correct cue → correct dog behavior → handler clicks = clean rep
- Correct cue → wrong dog behavior → handler clicks = wrong criteria
- Correct cue → correct behavior → handler doesn't click = missed
- Handler clicks during no-behavior moment = false mark

**Gate Day 21:** 8/10 correct on single cue.
**Gate Day 22:** 12/15 correct across all three cues.

---

### Days 23–24 — The Leash Game: Pressure Conditioning
**New input mechanic: press and hold.**

**Concept:** Dog on screen shown from above (top-down view). A leash line connects dog to handler icon. Handler presses and holds the PRESSURE button — leash tightens on screen. Dog must move toward handler to release tension. Handler releases the button when the dog moves toward them. Then presses REWARD.

**Day 23:** Dog always moves toward handler when pressure is applied (easy — conditioning phase).
**Day 24:** Dog occasionally pauses or resists for 0.5–1 second before moving. Handler must hold pressure steady — not increase it, not release early.

**Scoring:**
- Held pressure steady → dog moved → released on movement → paid = clean rep
- Released pressure before dog moved = too early, flagged ("Hold until they choose to move toward you.")
- Increased pressure (rapid re-press) = too heavy, flagged
- Paid before releasing pressure = flagged

**Cold test (Day 24 end):** Pressure applied once with no prior warmup. Does the dog on screen snap toward handler immediately? (Animated.) Handler self-reports whether their real dog did the same.

**Gate Day 23:** 40+ flow reps.
**Gate Day 24:** Cold test self-report passed + 40+ flow reps.

---

### Days 25–26 — The Leash Game: Cue + Pressure
**Two-input mechanic: cue word displayed + pressure button available.**

**Concept:** Cue word appears on screen. Handler waits 1.5 seconds. If dog responds = click and pay, no pressure needed. If dog doesn't respond in 1.5 seconds = pressure assist option activates. Handler applies pressure → dog moves into position → handler releases → clicks → pays.

**Day 25:** One cue only.
**Day 26:** All three cues.

**Scoring:**
- Dog responds to verbal alone = clean rep (bonus points)
- Dog needed pressure assist = acceptable rep
- Handler applied pressure before 1.5 seconds = too fast, flagged ("Give the verbal cue time to land.")
- Handler never applied pressure and dog didn't respond = missed

**Gate Day 25:** 15+ reps, 6+ verbal-only responses.
**Gate Day 26:** All three commands, 10+ verbal-only across 15 trials.

---

### Days 27–29 — The Hold Game: Distraction Proofing
**Simultaneous event mechanic.**

**Concept:** Dog is in position on screen (sit, down, or place). A distraction event plays. Handler must NOT click during the distraction — they wait for the dog to hold through it, then click the hold.

**Distraction ladder (same across Days 27–29, increasing intensity):**

| Level | Day 27 (Handler) | Day 28 (Environmental) | Day 29 (Social) |
|-------|-----------------|----------------------|-----------------|
| 1 | Handler takes 1 step back | Food appears 10ft away | Person walks through background |
| 2 | Handler takes 2 steps | Food moves to 5ft | Person sits nearby |
| 3 | Handler turns around | Food slides past | Person talks (audio) |
| 4 | Handler crouches | Loud sound plays | Person crouches near dog |
| 5 | Handler steps off screen | Food placed next to dog | Doorbell sound |
| 6 | — | — | Person makes eye contact with dog |

**Scoring:**
- Dog holds through distraction → handler clicks after = clean rep
- Handler clicks during distraction = too early, flagged ("Wait for the dog to prove they're holding.")
- Dog breaks position on screen → handler clicks anyway = wrong, flagged
- Dog holds → handler misses the click = missed

**Gate Day 27:** Dog holds through level 3+ across all three positions.
**Gate Day 28:** Dog holds through level 3+ with environmental distractions.
**Gate Day 29:** Dog holds through level 4+ with social distractions.

---

### Day 30 — The Full Run: Diagnostic
**No new mechanic. Full mixed session.**

**Concept:** 15-trial session. Random cue words. Random distraction events. All three positions. Handler must respond correctly to each combination.

**Output:** Completion report card with scores across all game dimensions the handler has worked through. Designed to be screenshot-able / shareable.

**Categories scored:**
- Timing accuracy (avg ms from behavior to mark)
- Criteria selection accuracy (% correct behavior clicked)
- Cue response rate (% verbal-only vs. pressure-assisted)
- Hold success rate under distraction (by level)

**No gate.** This is a snapshot. The report becomes the baseline for Phase 2.

---

## Difficulty Scaling Summary

| Days | Game | Core Skill | What Makes It Harder |
|------|------|-----------|---------------------|
| 11–12 | Clicker | Timing | Micro-movements added, cold test |
| 13–14 | Clicker | Criteria (eye contact) | Duration added |
| 15–16 | Shape | Criteria (sit) | Less frequent offers |
| 17 | Shape | Criteria (down) | New target, must ignore sit |
| 18 | Shape | Chaining | Multi-step sequence |
| 19 | Shape | Duration | Must wait before clicking |
| 20 | Shape | Mixed criteria | All three in one session |
| 21–22 | Cue | Verbal response | Three cues randomized |
| 23–24 | Leash | Pressure mechanics | Dog resistance, cold test |
| 25–26 | Leash | Dual cue | Verbal + pressure combined |
| 27–29 | Hold | Distraction proofing | Increasing distraction intensity |
| 30 | Full Run | All skills | Combined, randomized |

---

## Technical Notes for Claude Code

- Dog animations: sprite sheet or CSS transitions on image swap. 6+ states minimum per game phase.
- All timing is client-side timestamp delta (Date.now() at button press vs. behavior state change).
- Game state machine per session: `idle → behavior_transition → behavior_settled → mark_window → reward_window → next_rep`
- Gate conditions are evaluated server-side or in persistent state after session end — not during play.
- Sessions are resumable (handler interrupted mid-session = progress saved, picks up on next open).
- Phase 1 (Days 1–10) is pure logging UI — no game engine needed.
- Feedback strings should be stored in a separate content file so Evan can edit them without touching logic.
- All scoring thresholds (0.3 seconds for clean mark, etc.) should be config values, not hardcoded — they will be tuned.

---

*Game design spec v1.0 — PPP internal use — pair with ppp_30day_framework.md*
