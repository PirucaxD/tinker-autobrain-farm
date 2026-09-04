# Tinker AutoBrain Farm

An auto-farm brain for Dota 2's Tinker on the UCZone Lua scripting platform.
It farms lanes and jungle, and as of v0.1.260 it has a **Defense phase**: it
reacts to enemy disables and threats with defensive item saves and escapes.
It never auto-engages enemy heroes. Offense and combo layers are planned
follow-ups on the same shared `lib/`.

Current build: **Tinker.lua v0.1.415**. The script file, the in-game menu and
the log lines all still identify themselves as `Tinker` (the log analyzer and
every saved log key off that), so only the project name changed here.

## What changed since v0.1.374 (for returning testers)

- **Death logging now sees the Blink Dagger (v0.1.406).** No behaviour. The
  death log lists which escape items you held and whether each was ready, but it
  walked the save-dispatcher's item list, which deliberately does not include the
  dagger. So a hero who died holding only a dagger was logged as holding nothing,
  which is the exact misreading the death instrument exists to prevent. The
  dagger is now listed separately, and the readiness check is failure-guarded so
  a death can never be lost to an error while recording it.
- **Diagnostics and documentation (v0.1.403 to v0.1.405).** No behaviour in any
  of the three. v0.1.403 corrected three comments that described the tree and
  tower code incorrectly, including one that invited a source reordering which
  would have silently broken every tower query. v0.1.404 added a refusal census
  to the escape blink: that function previously logged only on success, so when
  it declined there was no way to tell which gate refused. v0.1.405 added
  engage-side timestamps so a camp trip can be reconstructed offline against the
  wave clock. If you are reading logs, v0.1.404 and v0.1.405 give you strictly
  more to read.
- **Dead code removal (v0.1.402).** No behaviour: three symbols were removed
  and every one of them had zero readers anywhere, verified across this repo,
  the deployed tree and the two sibling hero packages. The proof is at function
  level: 221 compiled functions before and after, exactly three differing, each
  matching one intended edit. Frees one of Lua's 200 local slots in the main
  chunk, which is the tightest constraint in this file.
- **Comment and documentation pass (v0.1.401).** No behaviour: the code is
  byte-identical to v0.1.400 once comments are stripped, and only the version
  banner differs. Every hard source line-number reference inside comments was
  replaced by the name of the function or symbol it pointed at, because those
  numbers rot on every edit and several were already pointing at the wrong
  place. A number of comments that described the code incorrectly were also
  corrected against the source, including a tower-safety radius, a March
  coverage figure, and several references to libraries that were merged away in
  v0.1.395 to v0.1.399. If you read the source to understand the brain, this is
  the release that makes that cheaper.
- **The shared libraries were consolidated (v0.1.395 to v0.1.399).** Five libs
  were absorbed into the three that already owned their domain: `route` and
  `schedule` into `lane` (now `Lane.Route` / `Lane.Schedule`), `nav` and
  `towers` into `map` (`Map.Nav` / `Map.Towers`), and `vision` into `escape`
  (`Escape.Vision`). Fewer files, one require each, and every previous export
  keeps its name. If you install more than one hero package into the same
  `scripts/lib`, note that the older packages ship the pre-merge files.
- **A stale-library tripwire that never worked (v0.1.399).** The check that
  warns you when another package overwrites a shared lib with an older copy
  read its logger before that logger existed, so it had been silently unable
  to print since it was added. It works now, which matters if you run several
  hero scripts side by side.
- **Keen affordability (v0.1.397 to v0.1.398).** A lane teleport that could not
  fund its March on arrival used to commit anyway and then stand there. It now
  defers a tick or two and drinks a bottle charge first when that closes the
  gap. Shipped with a scope bug that broke teleports outright for one build;
  v0.1.398 is the fixed one.
- **Diagnostics honesty (v0.1.400).** The `w_lead_reject` line printed a
  time-to-arrival computed on a different threshold than the gate it was
  explaining, so a held wave logged absurd values like `tarr=6.7e27`. It was
  never read by anything that casts. Log-only fix.

## What changed in the v0.1.331 to v0.1.374 line

Real-game reference on this line: GPM roughly 420-500 with zero brain-owned
deaths. Highlights:

- **W1 lead timing rebuilt (v0.1.371 + v0.1.374).** The first March of a wave
  is now timed to the casting position rather than to the hero, and the gate
  that fires it got its own radius instead of borrowing the approach-stop
  distance. The practical effect is that the robot stream and the creep wave
  now meet at the stand instead of the robots arriving after the wave has
  already walked past. Measured effective lead went from about 2.0s to about
  3.3s against a geometric ideal of 3.7s.
- **Death and respawn logging (v0.1.356).** Deaths were previously invisible
  in the log. `--farm-report` now prints a DEATHS block with a save census per
  death, so you can tell whether an escape existed and was on cooldown.
- **Commit risk v2 (v0.1.358).** A farm commit is now priced with a travel
  term, so a long trip into a lane an enemy can reach by the time you arrive
  scores worse than the same lane does right now.
- **Wave clock stamping fixed (v0.1.366).** Wave arrivals are stamped on the
  spawn grid rather than on the moment Tinker showed up, which removed a
  systematic error that rolled predicted arrivals a full period late.
- **Rearm channel watchdog (v0.1.355).** A rearm interrupted mid-channel no
  longer leaves the hero stuck; the stuck class went to zero.
- **Observed-farmer fix (v0.1.349).** An ally merely walking past a camp no
  longer marks it as being farmed. Camp retirement needs sustained presence.
- **New analyzer reports.** `--clock-report` (lane cadence and lost waves),
  `--time-report` (every second classified), `--state-report`, `--cycle-report`
  and `--keen-report` join the original audits.

Two housekeeping notes: `lib/vision.lua` is new and required, so pull the whole
`lib/` folder, and `lib/save_select.lua` was removed (it had no callers).

## What changed in the v0.1.265 to v0.1.331 line

- **Faction parity fixed.** A depth-ruler defect made Dire games camp under
  the T1 instead of stepping forward to the wave meeting ground like Radiant
  games did. Both factions now keen in, walk forward, and pre-cast at the
  meeting point.
- **Forward pre-cast posture.** The brain pre-positions ahead of the wave and
  pre-fires March so the wave dies on arrival, then keens away.
- **No more statues.** Stalled-wave holds, carried-away camp trips, and
  between-wave freezes all got explicit exits (stall release, contest
  re-check on arrival, idle pre-positioning at the next stand).
- **Keen level 2 raids are live.** Deep keen-dives onto allied creeps fire
  once Keen hits level 2, gated by the walk-depth law and a bail check.
- **Keen telemetry (v0.1.331).** Every teleport now logs its jump distance,
  landing residual, purpose, and mana, and a new `--keen-report` analyzer
  classifies every keen by outcome. If you want to help tune teleport
  efficiency, attach that report to your issue.

## What it does

A timing-anchored decision brain built around Tinker's kit (March of the
Machines, Rearm, Keen Conveyance, Blink):

- **All-lanes farming.** Mid is the home lane while the enemy mid T1 stands;
  after it falls, all three lanes compete on risk-then-gold. Side-lane waves
  are anticipated from a per-lane wave cadence, so it dispatches to fogged
  lanes and lands as the wave arrives.
- **Jungle route planning.** A receding-horizon planner fills the slack
  between waves with camp clears (paired camps in one March footprint,
  stack-aware budgets, cost-aware fountain refills as routed stops).
- **Keen/Rearm transport.** Keen Conveyance to buildings, outposts, and (at
  level 2) allied creeps moves the hero; travel blink fires whenever it is
  safe. Landings are gated by tower range, walkability, and fog-aware risk.
- **Safety layer.** Fog-aware proximity risk with threat weighting, tower
  radius as the only hard positional veto, depth economics past the enemy T1
  line, defensive wave clears when an enemy wave crashes an allied tower, and
  proactive blink escape.
- **Bottle discipline.** Automatic bottle use in the field and chain-drinking
  at the fountain, never interrupting a Rearm channel.
- **Defense phase (new in v0.1.260).** A threat dispatcher watches enemy
  modifiers landing on the hero and fires defensive item saves through a
  priority chain (any of ~24 defensive items light up as you buy them), then
  breaks contact and re-decides. A kit-aware channel gate refuses to start
  the long Rearm/Keen channels within a ready disabler's cast range, and
  learns enemy cooldowns from observed casts so it does not over-defer.

Typical result on an itemless build: 420-500 GPM with zero brain-owned deaths.
GPM varies a lot with lane matchup and game length, and it ramps through a
game, so short games read low. Do not compare two games of different lengths.

## Layout

- `Tinker/Tinker.lua` - the brain (the deployable script).
- `lib/` - hero-agnostic libraries: map/camp data, lane wave scanning and
  prediction, route planning, scheduling, navigation, escape and risk math,
  plus KV-generated game data. Pure logic is engine-stubbed and unit-tested.
- `tools/run_tests.lua` - the offline test suite (844 tests, no game needed).
- `tools/parse_debuglog.lua` - the log analyzer (farm/depth audits, per-wave
  coverage, time and gold accounting, keen efficiency). Useful when
  reporting issues.

Comments in the code sometimes point at a design doc by name, like
`TINKER_SCHEDULE_DESIGN.md` or `TINKER_W_GEOMETRY_STUDY.md`. Those live in the
private development repo and are not shipped here, so the file names will not
resolve. They are left in deliberately: each one marks a decision that was
measured rather than guessed, and the comment right next to it carries the
conclusion, which is the part you actually need to read the code. Nothing in
the shipped code depends on them.

## Requirements

- The UCZone Dota 2 scripting platform, with scripts loading from
  `C:\Umbrella\scripts\`.
- A game as Tinker. Bot/demo games are fine and are what the brain is
  calibrated on.

## Install

Copy the brain and the libraries into the scripts directory:

```
cp Tinker/Tinker.lua  /c/Umbrella/scripts/Tinker.lua
cp lib/*.lua          /c/Umbrella/scripts/lib/
```

Load into a game as Tinker. The menu lives under Heroes > Hero List > Tinker >
Brain: enable "Auto-farm" and leave the rest at defaults. A debug overlay and
diagnostics toggles are available in the same menu.

## Help wanted: testing the new Defense phase

The farm layer is calibrated on hundreds of demo and bot games. The new
Defense phase (v0.1.260-265) is different: it only exercises against real
enemy pressure, which no demo game can produce. That is exactly where an
earlier field report from a tester caught a freeze the demo runs had masked
for weeks, so this is a genuine ask.

If you can run a few games (bot lobbies with disablers work great - Lion,
Shadow Shaman, Sand King, Vengeful Spirit - and real lobbies are even
better), these are the things worth checking:

- Does the hero react when a disable lands on him (an escape or a defensive
  item cast) instead of standing still?
- With defensive items in the inventory (Eul's, BKB, Lotus Orb, Hurricane
  Pike, Glimmer...), do the saves fire on the right threats?
- Near an enemy with a stun/hex, does he hold his Rearm/Keen channels
  briefly and then get on with farming - or does he idle too long or channel
  into an obvious stun?
- Any freeze, Lua error, or "just stands there" moment.

After a game, grep the interesting lines from the debug log:

```
grep -aE "defense_flee|save_fired|threat_unrecognized|channel_defer|engage_bail|en_cd_probe|Lua error" C:/Umbrella/debug.log
```

Open an issue with that output (or the whole debug.log) plus a line or two on
what you saw and what heroes were in the game. The en_cd_probe ok|nil line
is a one-shot API probe we especially want to see from real games.

## Testing and reporting issues

The brain logs structured telemetry to `C:\Umbrella\debug.log`. After a game:

```
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --farm-report
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --time-report
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --farm-audit
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --depth-audit
lua tools/parse_debuglog.lua C:/Umbrella/debug.log --keen-report
```

The audits should read zero violations; the reports show GPM, per-wave lane
coverage, and where the time and gold went. If you hit odd behavior, an issue
with the log file (or the relevant report output) attached is the fastest way
to get it fixed.

Offline development loop:

```
lua tools/run_tests.lua          # pure-Lua suite, expect 844 passing
luac -p Tinker/Tinker.lua        # byte-compile check
```

## License

MIT (see `LICENSE`).
