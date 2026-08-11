# v6.0.1

## Bug Fixes

- **Fixed: `snd update` re-downloaded every file, every time.**
  It decided what to fetch by comparing the manifest's hash for a module
  against a hash remembered from the last download — and that remembered hash
  was kept in a MUSHclient variable named `_snd_dlhash_<module>.lua`.  Variable
  names may only contain letters, digits and underscores, so the dot made the
  name illegal and the write was rejected; nothing checked the return value.
  The read then came back empty and every module compared as changed, so
  running the command twenty times downloaded all twenty files twenty times.

  Rather than just fix the name, the remembered hash is gone: the updater now
  hashes the file **actually on disk** and compares that.  It needs no
  bookkeeping to stay honest, so it is right on a fresh install, after a manual
  copy, after a reload, and after a failed write — none of which the old scheme
  survived.  Whether you have edited a module is likewise decided against the
  `.orig` baseline written when it was downloaded, which is what that file is
  for.

- **Fixed: the version was truncated to `6`.**
  MUSHclient stores a plugin's `version` attribute as a *number*, so a
  three-part version like `6.0.1` came back as `6` — which is what the load
  banner showed.  Every comparison against the published `VERSION` therefore
  saw a permanent mismatch, which on its own would have kept the update banner
  up forever and re-fetched the plugin file on every check.  The full version
  is now carried explicitly as a string and used everywhere.

- **Fixed: the update banner never went away.**
  Running `snd update` downloaded the modules, told you to reload, and then
  announced the same update again on the next login.  The banner compares the
  published `VERSION` against the version in the plugin file — and nothing
  updated the plugin file.  `do_update()`, the only caller of the code that
  replaces it, was never called from anywhere, so both `snd update` and
  `snd force update` refreshed modules and nothing else.  A module update now
  brings the plugin file itself up to date too.

  The write is also checked before the plugin is reloaded — it used to reload
  regardless, which on a failed write restarts the plugin expecting new code
  and silently gets the old file back.

  The check runs even when no module changed, so a release that only touches
  the plugin file still reaches you; a missing release tag now says which tag
  it wanted instead of a bare error; and a release whose plugin file disagrees
  with its published version is reported rather than quietly updating on every
  run forever.

  **Existing v6.0 installs need `Search_and_Destroy.xml` replaced by hand once**
  — the v6.0 plugin file has no way to replace itself.  Modules and sounds
  already update on their own, and your database is untouched.  From 6.0.1
  onward the plugin keeps itself current.

- **Fixed: `xset win` ignored what you asked it to do.**
  The alias accepts `on`, `off`, `show`, `hide`, `max`, `expand`, `min` and
  `collapse`, but ran a handler that takes no arguments and simply flipped
  visibility — so `xset win on` could turn the window **off**, and the
  expand/collapse forms did nothing at all.  Each option now does what it says.

- **Fixed: the miniwindow could go missing while you were away.**
  Two independent causes, both of which leave you staring at a client with no
  window:

  *Reconnecting.*  Disconnecting tears the window down and nothing put it back,
  so idling out and returning left no window.  It is now rebuilt on reconnect,
  honoring your show/hide setting so a window you deliberately hid stays
  hidden.

  *A resolution change.*  The window's position is restored from a previous
  session as absolute coordinates, and nothing checked them against the current
  desktop.  A monitor sleeping and waking, a laptop undocking, or a remote
  session resizing could leave the window parked outside the visible area —
  present, but invisible.  Worse, `xset winreset` restored the same saved
  coordinates, so the documented cure did not work either.  A window with
  nothing left on-screen to grab is now moved back, and says so.  One left
  deliberately half off the edge is untouched.

- **Fixed: a vanished miniwindow would not come back.**
  `xset win on` called `WindowShow` on the window handle, which does nothing
  when the window has been deleted — leaving `xset winreset` as the only
  command with any effect, because it is the only one that recreates it.
  Showing the window now rebuilds it first if it has gone, and toggling a
  window that has disappeared brings it back rather than recording another
  "off".

- **Clearer messages when you are on a quest.**
  `xcp` answered "not on a CP or GQ" — true, but unhelpful when you are on a
  quest and quest targeting is simply switched off, which nothing said.  Both
  `xcp` and `kw` now point at `xcp q` and `xqt` instead.

- **Fixed: `xcp` did nothing on a global quest.**
  Every place that set `current_activity` set it to `"cp"` or `"none"` — the
  gquest path set `player_on_gq` but never the activity — so on a GQ it stayed
  `"none"`, and both `xcp` entry points abort on that with "not on a CP or GQ"
  while the target list sat fully populated beside them.

- **Fixed: area targets sent you to the area entrance from inside the area.**
  When a target has no specific room to walk to, the plan is to hunt or `where`
  from within its area — but the route was still measured to that area's start
  room even when you were already standing in it.  In practice: two targets in
  one area, kill the first, `cp check` finds no room route, and `xcp` walks you
  back to the entrance.  Being in the target's area now costs 0 hops and moves
  you nowhere.

- **Fixed: room-name CP targets ignored what you had already seen.**
  When a campaign target is given as a room name, S&D finds every room of that
  name in the mapper and ranks the candidate areas.  It checked sightings for
  an exact mob-and-room-name pair — and a comment above it claimed "exact room
  match first, then area-wide", but the area-wide half was never written.  So
  if you had never seen the mob in a room of that exact name, every candidate
  area was ranked identically, discarding the fact that you may well have met
  the mob elsewhere in one of them.

  Areas where the mob has actually been seen now rank above areas where it has
  not, ordered by how often, and areas with no sighting at all are marked
  unlikely so routing leaves them for last.  An exact room sighting still wins
  outright.  When the mob has been seen nowhere, every candidate stays equally
  likely — guessing would be worse than admitting there is nothing to go on.

  Reported by **Obyron**, who had hit the same class of bug in 5.99 from the
  other direction: there the area-wide branch existed, but its condition could
  never be false, so it never ran.

# v6.0

## New Features

### Navigation

- **Room link annotations** (`xset rlink <room1> <room2> {note}`)  
  Connect any two room IDs with a short annotation note.  When a CP or GQ
  target's room appears in a configured link, the note is displayed alongside
  that mob in both the MUD target list and the miniwindow:
  ```
  14) Mimi Momoney (prosper) {6 room maze}
  ```
  TSP now uses room links as a routing fallback — see **Pathing redesign**
  below — but the note is always shown regardless of whether the link was
  actually used for routing.  `xset rlink` with no arguments lists all
  configured links; running `xset rlink <r1> <r2>` on an existing link removes
  it.

- **`xset mark` now actually resolves "missing start room" areas, not just
  `xrt`.**  Marking a room only ever wrote to the separate marks table —
  useful for `xrt <name>`, but invisible to real routing (`area_anchor_room`
  in pathing.lua, `get_start_room`'s exact-key lookup) and to `xset area list
  unset`, which both only ever read `areas.start_room`.  So marking an
  area's entry point (exactly what `xset area list unset`'s own hint text
  tells you to do) didn't remove it from that list, and didn't help TSP
  route to it either.  Now, whenever a mark's name exactly matches a known
  area key that has no start room configured — `xset mark` (bare, in that
  area), `xset mark <name> <roomid>`, and `xset marks edit` — it also fills
  in `areas.start_room`.  An area that already has one configured is never
  overwritten.

- **Navigation speed** (`xset speed [run|walk]`)  
  Sets the movement mode used during mapper-driven navigation to either `run`
  or `walk`.  Calling with no argument toggles between the two.  Defaults to
  `run`.

- **Smart `go` alias — navigate to current target with room-link awareness.**  
  Typing `go` with no index argument now navigates directly to the current CP,
  GQ, or quest target instead of failing silently.  The behavior adapts to the
  active activity:
  - **Quest:** routes to the mapper-resolved room ID (if known), or falls back
    to the area start room.  Populates the `nx` list for alternative room
    cycling the same way CP mobs do.
  - **CP / GQ:** checks whether the current target has a specific room ID with
    a room link configured; if yes, uses link-aware navigation; otherwise
    delegates to normal `xcp`/`xgq` routing.

  **Room-link chain navigation** — when the target room has a configured room
  link (set via `xset rlink <near> <far> {note}`), `go` automatically handles
  the two-leg journey:
  1. `mapper goto <near>` — routes to the link entrance (mapper-accessible).
  2. On arrival at the entrance: `mapper goto <far>` is attempted (succeeds for
     mapped connections; fails silently for true mazes where the player navigates
     manually).  A second `execute_in_room` waits for the player to reach the far
     room regardless of how they get there.
  3. On arrival at the target room: `action_on_destination_arrived()` fires
     normally (scan / consider, depending on the `xset nx` setting), and link
     state is cleared.

  `go <N>` (with a number) continues to work exactly as before — navigating to
  `gotoList[N]` from the last room search.

- **TSP pathing toggle** (`xset pathing on|off`)  
  `xset pathing` now toggles route optimization and reports the current state.
  `xhelp pathing` documents the feature.

- **Pathing redesign — findpath-first, three-tier room resolution**  
  Route distances are now computed with the Aardwolf mapper's own `findpath`
  as the primary source (our own BFS only kicks in as a fallback if the mapper
  module isn't loaded).  Every target — express or not — is resolved through
  the same three-tier fallback:
  1. **Direct** — path straight to the mob's specific best-kill room.
  2. **Room link** — if there's no direct path (or the room is a registered
     maze entrance, whose exits shuffle and can't be trusted for routing),
     falls back to a configured `xset rlink` connection: routes to the link's
     mapper-reachable near side, and treats the mob's own room as where you
     actually end up for the purpose of calculating the *next* target's
     distance.
  3. **Area start room** — always-available last resort.
  This replaces the old express-only room lookup (non-express mobs previously
  skipped straight to the area start) with one consistent, more accurate
  resolution path for every target.

- **Route ordering is now a real nearest-neighbor chain, not a one-time
  sort from your starting room.**  Area groups used to be sorted once by
  distance from wherever you were standing when the route was built — so an
  area that happened to look close to your *starting* position could get
  visited before an area that was actually much closer to the *first* stop,
  forcing a backtrack across the map.  The route is now built as a proper
  chain: start room → nearest area, that area → whichever remaining area is
  nearest *from there*, and so on.  Difficulty is still a hard priority
  (every difficulty-1 area is chained before any difficulty-2 area), and
  express-grouping's `first`/`last` halves each chain independently, with
  the second half continuing from wherever the first half's chain ended.

- **TSP performance improvements**  
  Route optimization is significantly faster, especially on CPs with many
  targets spread across areas:
  - **Shared hop-count cache** — any room-to-room distance already computed
    during resolution is reused everywhere else it's needed (shared area start
    rooms, repeated room-link near sides, etc.) instead of being recalculated.
  - **Per-area start-room cache** — since many targets in a CP/GQ typically
    share an area, the area's start room is now looked up once and reused,
    not re-queried per mob.
  - **One resolution pass** — the old design queried a target's route room,
    then separately re-checked reachability with its own duplicate fallback
    queries if that failed.  Resolution and reachability are now the same
    single pass.

- **Express mob grouping** (`xset pathing express [off|first|last]`)  
  Controls where express mob areas appear in the optimized route:
  - `off` (default) — a single nearest-neighbor chain covers every area.
  - `first` — all areas containing at least one express mob are chained
    first; non-express areas are then chained on from wherever that left off.
  - `last` — same, with non-express chained first and express second.
  
  Within a mixed area (both express and non-express mobs), the express mob is
  listed first so the player navigates to the specific kill room before hunting
  the remaining mob from there.  In-area hop counts are shown for express mobs
  that require navigation within the area; non-express mobs show 0 hops (no
  specific room to navigate to).

- **Level buffer setting** (`xset level buffer <n>`)  
  `xset level buffer <n>` sets the number of levels above an area's stated
  maximum that still qualify as in-range for a room-type CP or GQ.  Default
  is 25.  `xhelp level buffer` documents the feature.

---

### Mob Hunting & Management

- **The hunt trick can no longer spam the MUD indefinitely.**  `ht_continue`
  fires on the game's "hunt found a mob" line and immediately hunts the next
  index; nothing in that loop is self-terminating, it ends only when
  `ht_complete` or `ht_fail` matches a line of output.  Quick-where has the
  same shape and was capped at 101 after it sent `where N.mob` forever in
  doors-and-fences areas — the hunt side never got the same guard, so
  unrecognised output would send `hunt N.mob` without limit.  Both now share a
  single named bound.

- **Per-mob difficulty ratings** (`xset mob difficulty [0-5] [mob]`)
  Rate how hard an individual mob is to *get to* on the same 1-5 scale as an
  area — your own assessment of the chore involved in reaching it, not a
  measure of how dangerous it is in a fight — defaulting to whatever you are
  currently targeting:
  ```
  xset mob difficulty            -- show the current target's rating
  xset mob difficulty 4          -- rate the current target 4
  xset mob difficulty 4 a orc    -- rate a named mob in the current zone
  xset mob difficulty 0          -- clear it, back to the area's rating
  ```
  Ratings are stored per mob per zone, so the same mob name in two areas is
  rated separately, and an unrated mob simply inherits its area's rating.

  A rating changes routing two ways.  An area is rated by the **average** of
  its targets, and only ever upward.  An unrated mob counts as its area's own
  rating, so an area with nothing rated averages exactly to itself and does
  not move; rating mobs pulls the average toward their numbers in proportion
  to how much of the area they represent:

  | Area rated | Targets                  | Effective |
  |------------|--------------------------|-----------|
  | 3          | four, none rated         | 3.0       |
  | 3          | four, one rated 5        | 3.5       |
  | 3          | four, three rated 5      | 4.5       |
  | 3          | two, both rated 1        | 3.0 (never demoted) |

  The value stays fractional — it is only used to sort tiers, never shown — so
  a 3.5 area slots cleanly between plain-3 and plain-4 areas.  Difficulty
  outranks hop distance entirely, exactly as area difficulty already did.
  Within an area, the easiest-to-reach mobs are listed first, so you pick up
  the quick ones on the way in and leave the awkward one for last.  Express
  mobs are still listed before non-express ones regardless of rating: that
  ordering is about having a known kill room to navigate to, which is adjacent
  to but distinct from how awkward a mob is to reach.

  The **Diff** column in the CP/GQ window now shows the mob's own rating where
  it has one and its area's otherwise, and `xset mob tags` gained a Diff
  column.  Note that `xset mob clearflags` removes the rating along with the
  flags, and that a rating only affects a route while that mob is actually one
  of your targets.

- **`ht`'s hand-off to `qw` after "You seem unable to hunt that target"
  now correctly recognizes the very first `where` result.**  The hunt
  trick's exact-match check compared the target's name with stop-words
  removed ("the rabbit hound" → "rabbit hound") against the *raw* mob name
  text from the actual `where` output line — which always includes the
  article.  Since the two never matched, every line in the `where` results
  looked like "not found," so it kept retrying with an incremented index
  (`where 2.rabbit`, `where 3.rabbit`, ...) instead of stopping at the
  correct room, eventually exhausting into "Mob not found — Previous
  sightings" even when the mob's exact line was right there in the first
  response.

- **Express mob navigation now shows all similarly-named room locations and
  enables `nx` cycling.**  When `xcp` navigates to an express mob's room, S&D
  now also runs a room search for all other identically-named rooms in the area
  and displays the full location list.  If the mob is not in the expected room,
  the player can type `nx` to cycle through alternative locations — the same way
  non-express mobs work.  The express room (highest kill count) is always
  navigated to first; the list is shown as additional context.

- **Express mode toggle** (`xset express [on|off|<number>]`)  
  Globally enables or disables express navigation (route directly to the known
  kill room when kill-count data is available).  Passing a number sets the
  minimum kill count required before a mob qualifies as express (default: 2).
  `xset express` with no argument shows the current state and threshold.  Note:
  `xset mob express` is a separate per-mob unconditional override that always
  uses express regardless of this global toggle.

- **Per-mob express flag — flexible syntax** (`xset mob express [<mob> [here|<roomid>]]`)  
  `xset mob express` now works with or without arguments:
  - **No arguments:** uses your currently targeted mob and sets the express room
    to the room you are in.
  - **`<mob>`** or **`<mob> here`:** sets the express room to your current
    location for the named mob in the current zone.
  - **`<mob> <roomid>`:** sets the express room to a specific room ID — useful
    when you are not currently in the mob's room.

- **Mob level tracking infrastructure** (`xmobdeaths`)  
  Many areas contain multiple mobs with the same name at different levels — for
  example, "A hawk" in the Tree of Life exists at levels 175, 185, 193, 198,
  205, and 210.  When you `con` a hawk during a campaign, the difficulty band
  alone doesn't tell you which one it is.  `xmobdeaths` sends `mobdeaths here`
  and parses the output into a new `mob_duplicates` table, recording:
  - **How many distinct mobs** share that name in the area (the `count` field).
    A count of 1 means S&D can route confidently; a count of 6 means it should
    stay cautious rather than locking in an express room too early.
  - **Every level at which the mob has been seen dying.**  When `con` data
    narrows this to a single match, it appears as `[Lv N]` in the consider
    output, letting you immediately confirm whether the mob in front of you is
    your campaign or GQ target.

  This data also strengthens the area disambiguation logic used when two areas
  share a display name (such as School of Horror / sohtwo): the area with
  recorded kills for the mob name is preferred over one with none.  Run
  `xmobdeaths` once per area to populate the table; the data persists across
  sessions.

- **`noaction` mob flag** (`xset mob noaction <mob>`)  
  Convenience alias that sets `nowhere`, `nohunt`, and `noscan` all at once.
  Useful for mobs that share a name across many key IDs and cannot be located
  by any of the three methods (e.g. a mob with six different key IDs all in
  rooms named "Battlefields of Faith").  If all three flags are already on,
  the command turns them all off; otherwise it turns all three on.

- **`noscan` mob tag** (`xset mob noscan <mob>`)  
  Marks a mob that does not appear in `scan` output at all (the server simply
  does not report it).  When this flag is set, S&D skips the scan step for that
  mob entirely rather than waiting for results that will never arrive.  Listed
  alongside the existing `nohunt` and `nowhere` tags in `xset mob tags`.

- **`levelok` mob tag** (`xset mob levelok <mob>`)  
  Some areas contain a handful of mobs planted well outside the zone's
  normal level range (e.g. a level-40 mob in an otherwise level-90+ area).
  Room-name campaigns/GQs normally discard a room match whose area's level
  range doesn't cover the level the campaign/GQ was taken at — silently, even
  when the room name genuinely matched — so those mobs could never be
  targeted.  Flagging a mob `levelok` (while standing in its room) bypasses
  the level-range check for that specific mob/zone pair only; every other
  mob in the area is still filtered normally.  Listed alongside `nowhere`,
  `nohunt`, `noscan`, and `express` in `xset mob tags`.

- **`nowhere`/`nohunt`/`noscan` tags are now respected everywhere, not just
  in `ht`/`qw`/`qs`.**  A few less-common paths to the same commands weren't
  checking these tags at all: `smart_scan` (`xset nx smartscan`) and the
  `scan`/`scanhere` arrival actions (`xset nx scan` / `xset nx scanhere`)
  would scan for the current target regardless of `noscan`, and `ah` with no
  argument (auto-hunt on your current target) would hunt regardless of
  `nohunt`.  All three now check the tag first and print `Skipping scan/hunt
  — mob is tagged noscan/nohunt.` instead of sending the command, matching
  what `ht`/`qw`/`qs` already did.

- **Generated keywords no longer mangle apostrophes or hyphens Aardwolf
  treats as significant.**  Two related bugs in `gmkw`'s auto-generated
  keywords: the `elemental` area's apostrophe-preserving filter (for names
  like `dra'ork servant`) was actually dropping the apostrophe entirely
  (`draork servant`), and every mob name with a hyphen (`yama-uba`,
  `will-o-wisp`, `master-at-arms`, compound adjectives like `long-tailed
  green basilisk`) had its hyphens replaced with spaces, splitting a single
  keyword into two words. Aardwolf's command parser requires apostrophes and
  hyphens as literal characters — `con draork` and `kill yama uba` both fail
  where `con dra'ork` and `kill yama-uba` succeed. Both are now preserved.

- **Quick-where no longer spirals into a runaway retry loop when the current
  area refuses to run `where`.**  A few areas (the manor, notably) reply to
  `where` with "There are too many doors and fences to see who is in this
  area." instead of a normal result or "no match" line.  Neither of the
  QuickWhere triggers recognized that sentence, so nothing ever reset the
  quick-where state — the trigger group stayed enabled, and the next
  unrelated line of output that happened to look vaguely like a where-result
  got misread as "not found," incrementing the retry index and re-sending
  `where N.mob` again. Left unchecked this climbs indefinitely (`where
  47.treant`, `where 48.treant`, ...) and survives even an `hta` abort, since
  the hunt trick itself had already handed off to quick-where by that point.
  A dedicated trigger now catches the message directly and cleanly aborts
  quick-where (and the hunt trick, if that's still active) with an
  explanatory note instead.

- **Mob keyword management** (`xset kw` / `xset kw <keyword>`)  
  Stores a shorthand keyword for a mob, used when `hunt` is more reliable with
  a shorter keyword than the full mob name.  `xset kw` with no argument opens
  dialogs to choose the area, mob name, and keyword.  `xset kw <keyword>` sets
  the keyword for the current CP/GQ target directly, without dialogs.
  Keywords are stored in the database and applied automatically during hunting.

- **Consider output enhancement**  
  The raw MUD consider output is replaced by a clean, consistently formatted
  display showing the mob name, a color-coded difficulty range, activity tags,
  and (when mob death data is available) a narrowed level guess:
  ```
  [CP] Hill Giant                 +5 to +9    [Lv 85]
       Tavern Keeper               -2 to -4
  ```
  - Activity tags (`[CP]`, `[GQ]`, `[Q]`) are prepended in gold/magenta if the
    mob is on the current campaign, global quest, or personal quest target list.
  - Divine protection and shopkeeper mobs are shown consistently with the same
    tag/name format and an unkillable marker.
  - In smart noscan mode (`xset nx smartscan`), only activity targets are shown.

- **Consider outcome colors are now customizable.**  The 13 difficulty-band
  colors used in the formatted `con` output (cornflowerblue for "-20 and
  below" up through red for "+51 and above") were hardcoded.  They're now
  individually overridable in the settings popup under "Colors — Consider,"
  the same pattern used for every other color in the plugin — useful if
  you're migrating from Pwar's plugin and its color scheme feels more
  familiar, or you just want better contrast for your color scheme.

- **Consider output overwrite** (`xset con_overwrite`)  
  Toggles whether S&D's formatted `con` output replaces the raw MUD output
  (default: on) or is displayed alongside it.  Turn off if you prefer to see
  both the raw and annotated versions simultaneously.

- **Mob search (`ms`) rewritten with full syntax support.**  
  `ms <mob>`, `ms here <mob>`, `ms <areakey> <mob>`, `ms <mob> <level>`,
  or any combination.  The area qualifier is detected by checking if the
  first token is `here` or an exact area key; everything else is the mob
  name.  A trailing number filters to areas whose level range overlaps
  ±5 of that level.  Results join `mob_sightings`, `mob_kills`, and `areas`,
  showing room name, zone, level range, and kill count.  Results are sorted
  by match quality: exact name → whole word at end → whole word mid-name →
  prefix match, with shorter names ranked first within each tier.  Row numbers
  are clickable for instant navigation; `xmg <#>` also works.  Bare `ms`
  shows usage.  `xhelp ms` documents the command.

- **Autonav** (`xset autonav [on|off]`)  
  Opt-in, default **off**.  When `xcp` or `qw <mob>` resolves to exactly one
  mapper room, S&D auto-navigates to it immediately instead of waiting for a
  `go 1` click — matching Pwar's behavior for unambiguous targets.  If the
  search resolves to more than one room (a common room name like "The
  Kitchen"), the room list is still shown and requires a manual pick, so
  autonav never walks you into the wrong zone.  Applies uniformly to `xcp`
  (room-type and area-type) and plain `qw`; quest retargeting is
  deliberately excluded, since it can fire on GMCP events like reconnect —
  auto-walking there would move the player unexpectedly.

- **Area difficulty rating** (`xset area edit <key> difficulty <1-5>`)  
  Assigns a 1–5 difficulty rating to any area.  The TSP/pathing route planner
  uses this to prioritize easier areas first when generating the CP kill order:
  lower difficulty numbers are scheduled before higher ones.  Use this to push
  notoriously annoying or slow areas (labyrinths, clan halls with narrow access
  windows, areas requiring keys) toward the end of your route without removing
  them from the list entirely.

---

### Campaigns & Quests

- **A stalled `cp info` / `cp check` / `gq info` / `gq check` now says so.**
  All four clear the target list and redraw *before* sending their command, and
  all four passed no timeout callback — so a capture that never completed (server
  lag, or output whose end tag went unrecognised) left an empty CP/GQ tab with
  nothing said about why, indistinguishable from genuinely having no targets.
  Each now reports what timed out and which command to run again.  Successful
  captures are unaffected: the capture library clears the timeout callback the
  moment the end tag arrives.

- **CP difficulty prediction**  
  After each `cp check` resolves, S&D prints your level-specific CP history
  (average, best, and worst completion time) if you have at least 3 completed
  CPs at that level.  Requires no extra command — shows automatically alongside
  the target list.

- **Today's campaign count in the info bar** (`Today: X/Y`)  
  The info bar now shows how many campaigns you have completed today.  `X` is
  the total across all remorts for the day; `Y` is the count at your current
  superhero tier.  The values are session-only — nothing is written to the
  database.  They are populated automatically whenever `cp check` is run while
  not on a campaign, from the MUD's own "You have completed N campaign(s)
  today" / "...today at this superhero" output.

- **Quest premonition detection**  
  A trigger automatically catches the "You ignore your premonition and request
  another quest" line, allowing S&D to correctly handle the resulting quest
  state without manual intervention.

---

### Statistics & History

- **The campaign level now survives a plugin reload.**  `cp_info_level` — the
  level the current campaign was taken at — is persisted to `cp_level_taken`
  whenever `cp info` is parsed, but `init_xml_settings()` (which restores a
  dozen other globals on load) never read it back.  Reloading mid-campaign
  reset it to 0, and `build_room_targets` then filtered targets against level 0.

- **The campaign-time prediction no longer skips itself.**  It looked like it
  fell back to your character's level when the campaign level was unknown:
  `tonumber(cp_info_level) or tonumber(gmcp(...)) or 0`.  But `cp_info_level`
  starts as the number 0, and 0 is truthy in Lua — so the fallback could never
  run, and the `if level <= 0 then return end` guard on the next line silently
  skipped the prediction in exactly the case the fallback existed for.

- **Completing a campaign, GQ or quest that began before S&D loaded is now
  recorded.**  `history_start()` only runs off the "I have selected N targets"
  trigger (and the GQ/quest equivalents), so installing or reloading the plugin
  part way through an activity left no in-progress row.  On completion
  `history_end()` found nothing to update and returned early from inside its
  own `pcall` — which reports success — so the rewards were discarded, nothing
  was written, and the reward panel was shown anyway.  The run simply never
  appeared in history or stats, while looking like it had been recorded.
  Completions with no start row now insert one; the start time is genuinely
  unknown, so duration reads as zero rather than being invented.  Activities
  that end any other way (failed, reset) with no row are still ignored rather
  than fabricated.

- **Activity history log** (`snd history [quest|gquest|campaign]`)  
  Prints the last 20 completed activities from the persistent history database,
  optionally filtered by type.  Each entry shows the completion timestamp,
  number of targets, time taken, and rewards earned.

- **Session summary** (`snd summary`)  
  Prints a compact table of everything completed since the plugin loaded:
  campaign count, quest count, GQs won vs. entered, and total QP, TP, trains,
  practices, and gold earned.

- **Area kill heatmap** (`snd stats areas`)  
  Shows the 30 areas where you have accumulated the most kills, with total kill
  count and distinct mob type count per area (global across all characters).
  Helps identify which areas to prioritize learning.

- **Time-range modifiers for `snd stats`**  
  `snd stats quest`, `snd stats campaign`, `snd stats gquest`, and
  `snd stats overtime` now accept an optional period and count/qualifier to
  narrow results to any time window:
  ```
  snd stats quest              — all time (unchanged)
  snd stats quest day          — today (since midnight)
  snd stats quest day 45       — last 45 days
  snd stats quest day last     — yesterday
  snd stats quest week         — this week (Sun to now)
  snd stats quest week last    — previous full week (Sun–Sat)
  snd stats quest month        — this calendar month
  snd stats quest month 3      — last 3 calendar months
  snd stats quest month last   — previous calendar month
  snd stats quest year         — this calendar year
  snd stats quest year last    — previous calendar year
  ```
  The same modifiers work identically for `campaign`, `gquest`, and
  `overtime`.  `snd stats overtime` with no period still defaults to the
  rolling 14-day window.  Every output table now includes a title row
  showing the activity type and the active time window.

---

### Display & Output

- **Smart-noscan mode now hides unkillable mobs too.**  After a smart scan,
  only mobs on the activity list should be reported.  `consider_mob_line`
  filtered correctly, but `consider_unkillable` — which lives in the XML script
  block — guarded on `con_after_scan`, a chunk-local declared in
  `scanning.lua`.  A Lua local is not visible outside the file it is declared
  in, so from the XML that name resolved to a nil global and the guard silently
  never fired: shopkeepers and divinely-protected mobs were printed even when
  everything else was filtered out.  The flag is now read through an accessor
  that crosses chunks.  A sweep of every module local referenced from the XML
  confirmed this was the only such case.

- **The alternating row color matched in one place and not the other.**
  `color_alternating_row` was read with a default of `#0C0C1A` by the miniwindow
  and the settings popup, but `#000040` by the MUD-side target list — so until
  you set it explicitly, the same setting rendered two different colors
  depending on where you looked.  All four sites now use the value the settings
  popup declares.

- **Reward summary displayed in the tab on activity completion.**  
  When a campaign, global quest, or quest completes, the target list is replaced
  by a compact reward summary showing QP (with daily bonus noted separately),
  gold, TP, trains, and practices, plus the total time taken.  The summary
  persists until the next activity begins.  Quest rewards appear on the QST
  tab below the "You may quest again" line.

- **Table-formatted target notes** (`xset table notes` / `xset table width <n>`)  
  When table notes are enabled, the CP/GQ target list printed to the MUD output
  buffer is formatted in a fixed-width boxed table rather than plain lines.
  Width defaults to 80 characters; `xset table width <n>` adjusts it (max 150).

- **High-DPI displays no longer clip title bar / button text.**  The
  miniwindow's auto-scale heuristic only looked at screen resolution
  (`_screen_w / 1920`), which under-detects a common case: a 1920×1080
  display running Windows at 125–200% scaling still reports a "normal"
  resolution, but the OS renders every bit of text visibly larger, clipping
  chrome that was sized off the un-scaled font metrics.  The scale
  calculation now also checks the OS's actual DPI (`GetDeviceCaps(88)`,
  logical pixels per inch — 96 = 100%) and uses whichever of the two signals
  (resolution or DPI) calls for more scale, feeding a correctly-sized font
  into the same auto-selection this always used.  Not applied when you've
  manually picked a font/size via "Change Font..." — those settings are
  respected as-is.

- **Right-click context menu on the miniwindow.**  
  Right-clicking anywhere on the window background opens a menu with:
  - **Font size** — Small / Medium / Large (current size is checked).
  - **Tab visibility** — toggle the Campaign and Global Quest tabs on or off.
    The Quest tab is always visible.  If the active tab is hidden, the
    window automatically switches to the next available tab.
  - **Window controls** — Hide Window, Bring To Front, Send To Back.  
  Right-clicking directly on a tab header opens a shorter tab-specific menu:
  hide/show that tab (QST tab has no hide option) plus the font size options.

- **Sound alerts** (`xset sound`)  
  Toggles audio notifications that play when a target mob is found during scan
  or spotted nearby.  Requires `.wav` files included with the plugin.

- **Aimed mobs `(!)` now match correctly in scan/consider output.**  
  `strip_mob_flags` only recognized flags whose parenthesized text started
  with a letter (`(F)`, `(Wounded)`, etc.), so Aardwolf's Aimed flag — shown
  as a bare `(!)` rather than a word — was never stripped from the front of
  the mob name.  That left `(!) A ranger's target` unmatched against the
  stored `a ranger's target`, silently breaking `[CP]`/`[GQ]` tagging and
  `mob_sightings` storage for any mob you had aimed.

---

## Quality-of-Life Improvements

### Target Window

- **Modernized target window.**  
  The miniwindow has been redesigned with a cleaner, more information-dense
  layout:
  - **Info bar** between the tabs and the target list shows your current noexp
    status and your TNL (to-next-level).  `[+]` and `[-]` buttons let you raise
    or lower your auto-noexp TNL threshold in increments without opening any menu.
  - **Tab labels** now show contextual detail at a glance — the CP tab includes
    the level at which the campaign was taken; the GQ tab includes the GQ number
    and level range (e.g. `GQ · #1234 · 186-201 · 3`); the QST tab shows quest
    state (`QST ready`, `QST 5m`, `QST done!`, or plain `QST` when on a quest).
  - **Target rows** have a thin colored stripe on the left edge: green for alive
    targets with a known location, gray for dead, orange for the currently
    targeted mob, and red for unknown location.
  - **CP sub-header** shows "Campaign taken at level N" above the target list
    when that information is available.
  - **Stats footer** shows all-time completion stats for the active tab:
    total completed, average time, and personal best (`CP: 42 done  avg 8m 30s  best 3m 12s`).
  - Window size and font scale automatically with your screen resolution.

- **"Diff" column shows each target's area difficulty at a glance.**  
  The CP/GQ target list now includes a Diff column next to Hops, color-coded
  the same way as `xset area list` (gray → green → yellow → orange → red for
  difficulty 1 through 5).  Set an area's rating with
  `xset area edit <key> difficulty <1-5>`.  Blank for targets with an unknown
  or unrated area.

- **Font picker replaces fixed size options.**  
  Right-clicking a tab or the window background now shows "Change Font..."
  which opens the OS font picker dialog.  Any font, size, bold, or italic
  style may be chosen.  The selection is saved globally and reloaded on every
  session.  "Reset Font" returns to the auto-selected default (Dina → Courier
  New → Lucida Console, scaled to screen resolution).  The old Small/Medium/
  Large menu items are removed.

- **Window chrome scales with font size.**  
  The tab bar, info bar (noexp/TNL row), and stats footer heights are no longer
  fixed pixel constants.  Each section grows automatically to fit the chosen
  font so text is never clipped at large font sizes (e.g. 16 pt).

- **Settings tab (SET) — full in-window settings panel.**  
  A new **SET** tab is always visible alongside QST/CP/GQ.  Right-clicking
  anywhere and choosing "Settings..." also jumps to it.  The panel shows every
  user-editable setting with its current value and a live color swatch for
  color settings.  Clicking any row opens the appropriate editor:
  - **Font** → OS font picker (`utils.fontpicker`).
  - **Color** → OS color picker (`utils.pickcolour`) or hex `#RRGGBB` input
    as a fallback.
  - **Toggle** (On/Off) → flips immediately.
  - **Choice** → dropdown via `utils.choose`.
  Settings are grouped into categories:
  - **Font** — font family, size, bold, italic.
  - **Colors — Window** — active tab accent line, tab border, info bar BG,
    status bar BG (previously hardcoded).
  - **Colors — Tabs** — per-tab accent line overrides for QST, CP, and GQ,
    allowing each tab to have its own highlight color.
  - **Colors — Targets** — normal, targeted, server-dead, unknown, alternating
    row tint.
  - **Colors — Quest** — quest ready, quest complete, quest cooldown.
  - **Display** — list mode (scroll/expand), CP tab visibility, GQ tab
    visibility.
  - **Behavior** — debug mode toggle.

- **Scrollable and expandable target list.**  
  CP and GQ target lists are no longer clipped when they exceed the visible
  area.  Two modes are available (toggle via right-click on the **title bar**
  → "Auto-Expand List"):
  - **Scroll mode** (default): the window keeps its current size; a scrollbar
    appears on the right edge when the list is longer than the visible area.
    Click the upper half of the scrollbar track to page up, lower half to page
    down.
  - **Expand mode**: the window automatically grows to fit every entry in the
    active list.  Height is capped at 90% of the screen.

- **Tab order changed: QST → CP → GQ.**  Quest is now the first (leftmost)
  tab and is always visible.  Campaign and Global Quest tabs can be hidden
  via right-clicking a **tab** or the **title bar** menu.  The default active
  tab on load is now Quest.

- **Window close button.**  A × button in the title bar hides the window.
  Right-click the title bar → "Show Window" to restore it, or type
  `xset win show`.

- **Reward summary no longer overflows a short window.**  The QP/gold/TP/
  trains/practices summary that appears after completing a quest, CP, or GQ
  now stops drawing at the bottom of the list area instead of spilling past
  it, matching how the rest of the window already respects that boundary.

---

### Navigation & Automation

- **Quest room list appears automatically on quest accept.**  When a quest is
  assigned, S&D immediately searches for the target room and displays the
  matching room list — no need to type `go` first.  Subsequent `go` commands
  reuse the cached list without repeating the search.

- **Detour and resume — nav state is saved and restored automatically.**  
  Inspired by Obyron's workflow: if you use a room search (e.g. `ms` or `xwhere`)
  while navigating a CP/GQ target, S&D saves your current room list and `nx`
  position before overwriting it.  When you finish the detour and type `xcp`,
  S&D detects the saved state and navigates back to exactly the room you were
  checking — including the correct `nx` index — instead of starting the search
  over from room 1.
  - A message is shown when the save fires: `Nav saved for [Mob] — type 'xcp'
    to resume after your detour.`
  - On restore: `Resumed [Mob] — room N of M.`
  - The save is discarded automatically if the target is killed, the CP ends,
    or you explicitly navigate to a different target.

- **`xcp` auto-navigates for all target types.**  Previously, `xcp` only
  auto-navigated for express targets.  Now:
  - **Room CP:** navigates immediately to the best-matched room (the first
    result from the room search) in addition to showing the full room list.
  - **Area CP:** navigates to the area's start room.
  Express targets continue to navigate as before.

- **`nx-` no longer double-scans.**  Stepping to the previous room with
  `nx-` was always running an extra scan on top of whatever arrival action
  you'd configured with `xset nx` — a stray leftover that `nx` and `go` never
  had.  `nx-` now triggers only the one configured action, same as `nx`/`go`.

---

### Activity States & Feedback

- **Two distinct dead states for CP/GQ targets.**  
  - **Server-dead (waiting for respawn):** Mob appeared as `(Dead)` in
    `cp check` / `gq check` because someone else killed it.  Shown with a
    `[D]` prefix and grayed out — the mob still needs to be killed once it
    respawns.
  - **Player-killed (completed):** Player killed the mob themselves.  Shown
    with a strikethrough line through the mob name in the miniwindow,
    indicating it is done for this CP/GQ run.

- **Quest reward summary now displays immediately after quest completion.**
  The miniwindow QST tab shows QP, gold, TP, trains, and practices as soon as
  the quest is turned in, including during the cooldown period.  Previously the
  reward was only shown once the cooldown expired and the tab read "You may
  quest again."  The cooldown state now reads "Quest not ready." instead of
  the inaccurate "Not currently on a quest."

- **`[CP]`/`[GQ]`/`[Q]` scan tags now show up for unknown-location targets
  too.**  A room-type CP or GQ target whose location isn't in the mapper was
  silently never tagged during `scan`/`consider` even when it was standing
  right in front of you — the activity-tag check only recognized that case
  for area-type targets.  Both now tag correctly.

---

### Campaigns & Level Matching

- **Per-area level range override** (`xset level <areaid> <min> <max>`)  
  Some areas (e.g. `sohtwo` — Outer Space) have a stored level range that
  is too narrow, causing valid targets to be silently filtered out.  This
  command overrides the range used when matching room CP/GQ targets for that
  area.  `xset level <areaid> reset` removes the override.  The global level
  buffer still applies on top of the override max.  `xset level buffer` (no
  args) now lists all configured overrides alongside the buffer value.

- **Suppressed `** Ignoring (level...)` spam.**  Out-of-range room matches
  no longer print a line per result.  Targets with no reachable rooms
  continue to appear as `unknown` in the target list.

---

### Help & Debugging

- **Help system expanded and improved.**
  - `xhelp summary`, `xhelp pathing`, `xhelp level buffer`, `xhelp ms`, and
    entries for `xmobdeaths`, `xwhere`/`xw`, and `xg` refresh/reload added.
  - All `xset mob` subcommands (priority, nohunt, noscan, express, tags,
    clearflags, nowhere) are now reachable via `xhelp mob priority` etc.
    Similarly for `xset mark` and `xset maze` subcommands.
  - `xhelp <word>` now falls through to a full-text content search across all
    topic summaries, syntax lines, and section text when no topic name matches.
    Matched keywords are highlighted in results.
  - `xhelp summary` reorganized by category with clean 80-column alignment.

- **Every command now has help text, and the suite enforces it.**
  Commands live as aliases in the XML and documentation lives in a table in
  `help.lua`, with nothing linking the two — so a command added without a help
  entry stayed invisible until a user typed `xhelp` for it and got nothing
  back.  An audit of all 154 commands found nine undocumented, including
  `snd settings` (the entire settings window) and `xset mob levelok`.  All are
  now documented, along with `xset autonav`, `xset debug`, `xset import`, and
  `xset fontsize` / `xset linespace`.

  Command synonyms now resolve too: `xhelp xgui reload`, `xhelp xrunto`,
  `xhelp hta`, `xhelp xwh`, and `xhelp xset window` previously found nothing
  even though the commands themselves worked.

  `tests/help_coverage_test.lua` re-derives the command list from the XML on
  every run and fails on any command with no help text, so this cannot drift
  again.  It also catches duplicate topic names (which silently shadow a
  topic), `see_also` entries pointing at topics that do not exist, and topics
  that render empty.

- **Removed a dead alias.**  `xset sendecho` was declared with an empty script
  and no body, and was routed away from the MUD — typing it did nothing at all
  and said nothing about why.

- **Debug mode with persistent log file** (`xset debug on|off`)  
  When debug mode is enabled, all `DebugNote` output and all errors are written
  to a timestamped log file (`SnD_debug.log` in the MUSHclient data folder) in
  addition to appearing on screen.  The log can be sent directly to the
  developer for diagnosis.
  - `xset debug on` — enable debug mode, open the log, print its path.
  - `xset debug off` — flush and close the log.
  - `xset debug` — show current state and log path.
  - `snd debug` — show log file path.
  - `snd debug clear` — truncate the log without disabling debug mode.
  - Each log session opens with a header (S&D version, character name,
    timestamp) so multiple sessions in one file are distinguishable.
  - `ErrorNote` output is captured to the log whenever debug mode is on.
  - Out-of-level-range ignored rooms (previously suppressed) are now logged
    to the debug file automatically and also shown on screen in debug mode.

---

### Plugin Updates

- **Fixed: `snd changelog`, the version check and the plugin download never
  even tried.**  `download_file` guarded on a global `async_ok`, but the only
  places that variable was ever assigned declared it `local` inside another
  function.  The global stayed `nil`, so every call took the failure branch and
  printed "Error on file download" without contacting anything.

- **Fixed: `snd update` died on an assertion inside the async library.**
  The third argument to `doAsyncRemoteRequest` means different things in
  different versions of the Aardwolf package — the current one treats it as the
  protocol and infers it from the URL when omitted, while older copies treat it
  as the HTTP verb and reject a missing one.  The module bootstrap passed
  `"GET"` and worked; the update path passed nothing and raised, which only
  surfaced once the manifest URL was fixed and the request was actually
  attempted.  All downloads now go through one helper that tries the modern
  form and falls back to the older one, so either version of the package works.

- **Releases now ship the plugin's modules.**
  The archive contains `Search_and_Destroy.xml`, `sounds/` and `snd_modules/`,
  so a fresh install has working code the moment it is added — no waiting on a
  download before anything can run.  One-time files stay out of it:
  `seed_data.lua` runs once and deletes itself, and `areas.json` is fetched
  only when the areas table is empty, so shipping either would put a file in
  the archive that is stale as soon as it is used.

  `snd_modules/` beside the plugin is also where `snd update` writes, so a
  shipped install updates in place.  The folder is deliberately not called
  `lua/`: that name collides with the personal script folders people keep next
  to their plugins, and it is the path the plugin reserves for a development
  checkout.  Installs from the previous layout still find their modules and
  migrate on the next update.

- **Fixed: a fresh install opened with a wall of errors.**
  MUSHclient validates every trigger's and alias's script name the moment the
  plugin's script block finishes — before the plugin has had a chance to
  download anything.  On a first install the 81 functions the modules define
  did not exist yet, so a new user's first sight of S&D was around a hundred
  `subroutine could not be found` errors.  The plugin then downloaded its
  modules and worked fine, which made it worse: the errors were
  indistinguishable from a real failure.  The script block now declares a
  placeholder for any name that is not already defined, and loading the modules
  replaces them.

- **Fixed: your own `lua` folder could shadow the plugin's modules.**
  `<plugin>/lua/` was preferred over downloaded modules unconditionally.  S&D's
  module names — `util.lua`, `constants.lua`, `settings.lua`, `db.lua`,
  `window.lua`, `help.lua` — are exactly what a personal script folder tends to
  contain, so anyone keeping their own scripts beside their plugins could have
  their `util.lua` loaded in place of S&D's, failing in ways that look nothing
  like the cause.  That folder is now used only when it contains a `.dev`
  marker file.  If S&D modules are found there without one, it says so once
  rather than silently ignoring them.

- **The plugin now says when its modules cannot update.**
  `<plugin>/lua/` is the bootstrap's developer path: modules found there are
  loaded in preference to downloaded ones, and the updater deliberately never
  replaces them so a working copy survives an update.  Extracting the whole
  repository into your plugins folder produces exactly that layout — and then
  every module is pinned while the plugin XML keeps updating normally, leaving
  a new plugin beside stale modules.  It used to happen in total silence; now
  it is reported on load, with the folder named and how to silence it if it
  was intentional.

  Releases also ship an archive containing only the plugin and its sounds, so
  the source tree is not the obvious thing to download.

- **`tools/verify_release.py` checks what was actually published.**
  Every other check in the repository only sees local files, so a push that is
  behind, a file sent to the wrong path, or a missing release tag all look
  fine right up until a user hits them.  This probes the live repository
  through the same `SND_RAW_URL` / `SND_BRANCH` the shipped plugin uses and
  compares the published bytes against the local tree.

- **Every remote URL now derives from one configurable base.**
  The plugin downloads six things — itself, its modules, `manifest.json`,
  `changelog.md`, `areas.json`, and the sound files — and the URLs for them
  were spread across three files, two of them as chunk-locals that could not
  be overridden from anywhere.  Moving the repository meant finding all six.
  They now come from two lines in `Search_and_Destroy.xml`:
  ```
  SND_RAW_URL = "https://host/USER/REPO/~files/%s/%s"   -- branch, then path
  SND_BRANCH  = "alpha"
  ```
  The whole pattern is configurable rather than just the domain, because the
  path shape differs by host (Gitea's `~files/<branch>/<path>` versus GitHub's
  `raw.githubusercontent.com/USER/REPO/<branch>/<path>`).  A test fails the
  build if any file hardcodes a URL of its own.

- **Fixed: `xset sound` could never actually play a sound.**
  Playback looked for the `.wav` files loose in the MUSHclient base directory
  and nothing ever put them there.  A `download_sounds()` existed to fetch
  them but was never called from anywhere — and could not have worked if it
  had been, because it built its download list from two variables that were
  never assigned (both `nil`, so the list was empty) and wrote to a different
  directory than playback read from.  So a documented, help-indexed feature
  was inert on every install.

  The sound files now ship in a `sounds/` folder beside the plugin, and that
  dead download code is gone.  A missing folder reports once rather than on
  every scan.

- **Repointed to the public GitHub repository.**  `SND_RAW_URL` and
  `SND_BRANCH` now resolve to
  `raw.githubusercontent.com/AardCrowley/Search-and-Destroy-Revamp` on `main`.
  Modules, the manifest, the changelog and the seed data come from the branch;
  the plugin file itself is still pulled from a `v<version>` tag, so updating
  gets an immutable release rather than whatever `main` holds at that moment.

  Note that this is a **different repository** from the 5.x releases.  An
  existing 5.99 install checks `Search-and-Destroy/master` for updates and will
  never see this one, so upgrading from 5.x is a manual install rather than an
  automatic update.

- **Fixed: the update check could never fetch the manifest.**
  `manifest.json` lives at the repository root, but it was requested through a
  base URL ending in `lua/`, so `snd update` asked for `lua/manifest.json` and
  got a 404 every time.

- **`snd changelog` now shows what changed since *your* version.**
  The first time you load S&D after an update, the releases you have not seen
  yet are printed automatically, and `snd changelog` on its own does the same
  thing on demand:
  ```
  snd changelog                  -- what changed since your version
  snd changelog all              -- the complete history
  snd changelog since 6.0        -- everything newer than a given version
  ```
  If you are already on the newest release it says so, rather than printing
  nothing — silence is hard to tell apart from a broken command.  If the
  download fails, nothing is recorded as seen, so the notice returns on the
  next load instead of being lost.

  This existed in name only before.  The version-diff branch was unreachable
  (`get_changelog` was only ever called in "show everything" mode), the
  version it compared against was written to settings but never read back so
  it was `nil` on every load, the comparison ran `tonumber()` over version
  strings and would raise on anything that was not a plain number, and the
  URL pointed at a JSON file that does not exist.  Releases are now sections
  in this file, keyed by a `# v<version>` heading and rendered directly.

- **`snd update` now protects local edits instead of quietly reverting
  them.**  If you've tweaked a module file yourself, updating used to apply
  the new upstream version of anything you'd changed and stash your edit in
  a separate `<file>.user.lua` file for you to notice and manually re-apply —
  effectively reverting your change on every update unless you caught it.
  The merge now keeps your edit **live** in the updated file whenever
  upstream hasn't touched that same code; you only see a sidecar note when
  there's a genuine conflict (both sides changed the same thing, or upstream
  removed something you'd modified) that needs your judgment call.
  - **Blank-line-only edits no longer count as a modification** — an extra
    or missing blank line won't trigger a merge or a backup.
  - **The merged result is validated before it's ever written.**  If a merge
    wouldn't produce valid Lua, your existing file is left completely
    untouched and the update reports exactly why the merge failed (with the
    Lua error) instead of silently installing something broken.
  - A backup of your file (`<file>.backup`) is always written before a merge
    is attempted, regardless of outcome.
  - The post-update summary now separately reports plain updates, merges
    with edits preserved, merges needing manual review, and any merge or
    download that failed validation.

---

## What the Revamp Changed Structurally

v6.0 is not a feature patch on top of the original S&D — it is a ground-up
rewrite that happens to preserve all user-facing commands.  The public master
release was a single monolithic XML file containing ~10,000 lines of inline
Lua.  v6.0 replaced that with a proper multi-file plugin architecture.  The
changes below are invisible to the player but explain why the internals look
completely different.

- **Modular Lua architecture.**  
  All code was extracted from the XML script block and split into 17 focused
  modules, each loaded at startup via `dofile`:
  `constants`, `util`, `db`, `settings`, `characters`, `areas`, `mobs`,
  `keywords`, `targets`, `pathing`, `express`, `navigation`, `hunting`,
  `scanning`, `history`, `window`, and `help`.  Each module has a single
  responsibility and declared dependencies.  This makes the codebase
  navigable, testable, and patchable without touching the XML.

- **SQLite database backend.**  
  The original plugin used MUSHclient's `GetVariable`/`SetVariable` store,
  which persists data in an XML state file.  State files are prone to
  corruption, and a single corrupt file means total data loss with no
  recovery path.  SQLite's write-ahead logging and atomic commit model make
  it significantly more resistant to corruption, providing a much more stable
  long-term store.  v6.0 persists all state in `SnDdb.db`.  Tables include:
  `characters`, `areas`, `mob_sightings`, `mob_kills`, `mob_keywords`,
  `mob_tags`, `maze_rooms`, `history`, `settings`, `mob_duplicates`, and
  `room_links`.

- **Per-character and global settings.**  
  Settings moved from MUSHclient plugin variables into the `settings` DB table
  with explicit `char_id` scoping.  Global settings (font, colors, express
  mode) are shared across all characters.  Per-character settings (CP level,
  noexp threshold, nx action) are isolated per character.  The old variable
  names are migrated automatically on first load.

- **GMCP-native character identity.**  
  Character identification (used to scope per-character DB rows) is now driven
  entirely by GMCP data (`char.base.name`), replacing a fragile variable-based
  approach.

- **TSP route optimizer.**  
  A Traveling Salesman Problem solver (`pathing.lua`) computes the shortest
  route through all CP/GQ targets using the mapper's room-distance data.
  Route optimization can be toggled with `xset pathing on|off`.

- **Themed miniwindow.**  
  The target display was rewritten from a plain-text miniwindow into a
  fully-themed, tabbed interface (`window.lua`) that integrates with the
  Aardwolf package theme system.  It auto-inherits color scheme changes and
  participates in the z-order and layout-lock systems.

- **Bootstrap / auto-update.**  
  The plugin can download missing or outdated module files from the Gitea
  server on first install or after an update, then load them without a full
  plugin reinstall.  Module files in the local `lua/` dev folder always take
  precedence over downloaded versions.

- **Help system.**  
  `xhelp` was rewritten as a structured topic system (`help.lua`) with
  category groupings, full-text search, and per-subcommand entries — replacing
  scattered `InfoNote` blocks throughout the codebase.

---

## This Changelog

This file (`changelog.md`) documents all changes in human-readable Markdown
form and tracks v6.0 additions relative to the **public master release** of
S&D (not the private Beta 5.99 branch).  Features that exist in Beta 5.99
but were not yet in master at the time of v6.0 development may appear here
if they were independently re-implemented or extended; a full diff of master
vs. Beta 5.99 has not yet been completed.

Prior version history (v5.0–v5.x) is recorded in the `changelog` JSON file.

### Format

Each release is a level-1 heading — `# v6.0`, `# v6.1` — and everything under
it, up to the next such heading, belongs to that release.  Newest goes first.
Level 1 is reserved for this purpose: the document's own structure starts at
level 2, so a new release is added by prepending a heading, never by
renumbering existing content.

The plugin parses these headings to show a user only what changed since the
version they were running (`snd changelog`), so the version in the heading
must match the plugin's own version string — dotted numbers, `6.1`, not
`alpha-9`.  Anything before the first `# v` heading is ignored, which is why
this note is safe to keep here.
