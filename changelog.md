# v6.0.6-dev

**A development build.**  Nothing here is in a public release yet.  Run
`snd version` to see whether you are on one of these.

## Bug Fixes

- **Fixed: `xcp` ignored a configured `xset rlink` for a room-named campaign
  target, and for an express target whose room wasn't flagged as a maze.**
  `go_to_current_target` ('go') has always honored any configured link
  unconditionally; `xcp_goto_target` only ever checked one for an express
  target, and only when the mapper's own data flagged that room as a maze
  room — a room-CP target never checked at all, and an express target
  behind some other kind of obstacle (a locked door, a portal-only room)
  with a genuinely configured link still got ignored. Both routes now check
  for a link first, unconditionally, before falling back to the area
  entrance — matching what `go` already did.

- **Fixed: `go`/`go <N>` also ignored a configured `xset rlink` — the case
  that matters most, since it's what actually runs for every real `go` once
  `xcp`'s own arrival search has populated the room list.** The link-aware
  routing in `go_to_current_target` only ever covers the case where that
  list is still empty; in normal play (`xcp` → arrival search populates the
  list → `go`) it never is by the time `go` runs, so the indexed branch —
  which walked straight to the destination with no link check at all — is
  what every real `go` took. Same fix as above: check for a link first,
  unconditionally, before walking straight there.
  Reported upstream with a full root-cause writeup and a working PR by
  **tonybustamante**.

- **Fixed: `xcp` could report "no reachable targets" right after switching
  to a campaign or gquest that still had live ones.** Finishing one of two
  simultaneous activities (a gquest completing while a campaign is still
  running, or vice versa) already moved the miniwindow's tab focus to
  whichever was still active — but `main_target_list` and `current_activity`
  stayed pointed at the one that just ended, so `xcp` kept iterating its
  now-empty list. Ending either one now rebuilds the target list for
  whichever is still running, the same way switching to its tab by hand
  already does.

- **Fixed: `nx` could bounce between the same two rooms forever, or claim a
  detour that never happened, when a campaign/gquest target had several
  same-named rooms.** The automatic quick-where that fires on `nx`/`xcp`
  arrival re-searches the target's own mob, and that re-search always reset
  `nx`'s position back to room 1 — discarding all progress every single
  arrival, on any list with duplicate room names. It was also
  indistinguishable from a genuine detour (searching some *other* mob mid
  navigation), so it printed a spurious "Nav saved — type 'xcp' to resume"
  for a navigation that was never interrupted. This kind of self-search is
  now recognized for what it is: when it resolves to the exact same room
  the list was already on, `nx`'s position is kept instead of reset, and no
  detour is recorded. (A same-room-set re-search that gets re-sorted by the
  arrival scan/con action — moving that room to a different position in the
  list — falls back to the ordinary reset rather than risk pointing `nx` at
  the wrong room.)
  Reported by **Obyron** (an 11-room list bouncing `nx` between the first
  two rooms) and **Cephrael** (the spurious "Nav saved" and a hunt/where
  cycle that never progressed).

- **Fixed: a campaign mob whose area S&D guessed wrong could stay listed
  and "alive" after being killed, with `xcp` routing back to it until a
  manual `cp check`.** The local kill match can occasionally resolve an
  ambiguous mob or room to the wrong area, or miss a kill the damage
  tracker never saw; nothing after that resynced against the server's own
  list short of the player typing `cp check` themselves. A campaign kill
  now also queues a background `cp check` shortly after, self-healing
  anything the local match got wrong the same way it already does for
  gquest kills.
  Reported by **Obyron**.

## New

- **`cp reroll <n>` now sends the number the game actually means.**
  Oracles' premonition skill rerolls one campaign target by its position in
  the game's *original* numbering — not the route-optimized order S&D
  displays the list in, which routinely disagrees with it. `cp reroll <n>`
  now translates `<n>` automatically, using the numbered list Oracles are
  shown on taking a new campaign. If S&D can't confirm the translation, it
  refuses rather than guessing, and shows you the original numbered list so
  you can read the right number off yourself. `campaign reroll <n>` (the
  full word) is a deliberate escape hatch that is never translated.

- **Right-click a target list row for its own settings.**  Every per-mob and
  per-area command S&D has — nohunt, nowhere, noscan, levelok, difficulty,
  express — used to be CLI-only, and assumed you were standing in the
  target's own zone. A right-click on any row now opens a menu of the same
  settings, scoped to that row's own mob and area regardless of where you
  actually are. Campaign rows also get a premonition reroll option.

# v6.0.5

## Bug Fixes

- **Fixed: the quest tab flashed for events that had nothing to look at.**
  Any quest event mid-campaign or mid-gquest — a new target, a kill, the
  quest ending — flashed the quest tab, not just the cooldown becoming ready
  again. Only a `ready` transition actually means something worth switching
  to eventually; the rest are just data updates. Only `ready` flashes now.

  Requesting a quest yourself while mid-campaign/gquest also used to only
  flash, the same as a passive event — but that's a deliberate action, not
  something happening in the background, so it now switches straight to the
  quest tab instead, the same way `xcp` earns the tab by navigating there.
  It stays there until you switch back yourself, or `cp check`/`gq check`
  does — both are a deliberate look back at the campaign/gquest, so both
  return the tab to it.

- **Fixed: hunt trick (or `where`) could fire on its own for an express
  mob.**  `xcp mode ht`/`qw` auto-fired on arrival however `xcp` got you
  there, including an express jump — but an express room is a remembered
  kill spot, not a guess the way a campaign-named or area-entrance room is,
  so nothing should hunt or `where` the instant you land there. `xcp` on an
  express mob now only walks you to the room and loads it as your target.
  If the mob is not there, run `ht`/`qw` yourself, or use `nx` to cycle the
  other rooms sharing that name — `nx` is the one place that does still
  fire the `xcp mode` action automatically, since reaching for it at all
  means express guessed wrong.
  Reported by **Selitos**.

- **Fixed: switching to `xset win tabs single` could leave no way back.**
  The right-click menu's checkable items (Single Tab, Auto-Expand List, Show
  Campaign/GQ Tab) used WindowMenu's checked-item marker to show a tick —
  which rendered as a grayed-out, unclickable entry instead, in at least one
  player's MUSHclient.  Once a setting became checked, the one menu item
  that could un-set it stopped responding to clicks at all — for single-tab
  mode specifically, that meant no way back to multiple tabs from the menu.
  Every one of those items now names the action a click performs directly in
  its label ("Show All Tabs" / "Show Single Tab Only", etc.) instead of
  relying on a checkmark — the same safe pattern the window's own
  show/hide toggle already used without issue.  `xset win tabs multi`
  (typed) was never affected, and still works either way.
  Reported live, with the exact symptom ("grayed out instead of ticked")
  that pinned it down.

- **Fixed: turning `xset express` off and back on could resurrect mobs
  already killed in between.**  Rebuilding the target list — which toggling
  express does, but so does anything else that calls it — reads from the
  last real `cp check`/`cp info` (or the gquest equivalents), which does not
  know about a kill made through the plugin since then; a kill only ever
  marks the in-memory list, with no way back into the check data it was
  built from. A rebuild now carries forward anything already marked dead
  (and a lower gquest kill count, for a multi-count entry) onto the fresh
  list, matched the same way a kill is recorded in the first place.

- **Fixed: an express target behind a maze room ignored a configured
  `xset rlink` and always routed to the area entrance instead**, even with
  the custom mapper exits (`cexits`) needed to actually reach it, and even
  though `go`/`qw` could already get there through the same link.  `xcp`'s
  own navigation never consulted a configured link for a maze room, only
  `go_to_current_target` did.  It now tries the link first, the same
  two-hop way `go` already does — to the link's near side, then attempting
  the real target room, which succeeds when `cexits` give the mapper a
  genuine path through what would otherwise be an untrustworthy maze — and
  only falls back to the area entrance when no link is configured.
## New

- **The default express kill-count threshold is now 3, up from 2.**  Express
  is meant for a mob you can confidently point at one specific room; 2 kills
  in the same room was flagging some mobs express too eagerly. Still fully
  configurable with `xset express <number>` — this only changes what a fresh
  install, or a character who never touched the setting, starts with.

- **`xset mob unexpress <mob>` — remove express from one mob without
  clearing everything else.**  The only prior way to remove express from a
  single mob was `clearflags`, which wipes every other flag and the
  difficulty rating along with it. `unexpress` forces express off and clears
  its pinned room, leaving everything else untouched — and unlike running
  `xset mob express` again, it always turns it off rather than toggling
  (which only undoes a set made from the same zone it was set in).
  `xset mob priority`/`unpriority` are gone: they set/cleared the same
  pinned-room data `express` already writes, nobody used them on their own,
  and `unpriority` alone could silently strip an express mob's destination
  room while leaving express on. `express` is now the only thing that ever
  sets a pinned room.

- **`xset win tabs single` — one tab instead of three.**  Collapses quest,
  CP, and GQ down to a single tab that always shows whichever is currently
  active, instead of three you click between.  `xset win tabs multi` goes
  back to the usual three; bare `xset win tabs` reports which you're in.
  Also available from the right-click menu.  Finishing a campaign or gquest
  while the other is still running moves the tab to what's still active
  instead of leaving it on a now-empty one — true in multi-tab mode too, but
  it's what makes single-tab mode actually track the active activity rather
  than getting stuck.  A quest event with no separate quest tab to flash
  flashes the one tab you have instead.

- **`snd changelog auto [on|off]` — turn off the automatic notice on
  update.**  On by default, same as always: the changelog since your last
  version shows once, automatically, the first time a new version loads.
  Turning it off doesn't lose anything — `snd changelog`, run by hand, still
  shows everything since the version you actually last saw, even after
  several updates went by unannounced.

# v6.0.4

## Bug Fixes

- **Fixed: `xcp mode ht` could cancel its own `where` the moment a hunt
  trick had escalated past the first same-named mob.**  Arriving at the
  target sends `where` to pin down the exact room, then cleans up any of the
  hunt trick's own leftover `hunt N.mob` replies still queued server-side by
  sending `stop` — but `stop` clears the whole pending command queue, not
  just hunt commands, and it ran *after* the `where` had already gone out.
  So any hunt trick that took more than one try — several mobs sharing a
  keyword, ordinary and unremarkable — sent `where`, then immediately
  canceled it. The cleanup now runs first.
  Reported by **MiSolo**, who traced it to the exact line.

- **Fixed: `xcp` could silently navigate to the wrong activity when running
  a campaign and a global quest at the same time.**  There is only the one
  navigator for both, and it acted on whichever was checked most recently —
  which is not necessarily the one you meant, and could change in the
  background (a gquest kill re-checks the gquest on its own).  `xcp` now
  notices when the tab you're looking at disagrees with the one it was about
  to act on, and switches to match before doing anything, saying so out
  loud.  Only applies when both are actually running; a single active
  campaign or gquest is unaffected.

- **Fixed: the "Today" campaign count in the miniwindow only updated if you
  ran `cp check` by hand while between campaigns.**  Aardwolf only includes
  "You have completed N campaign(s) today" in `cp check`'s response while
  you are not currently on one — actively working a campaign never showed
  it at all, no matter how many you finished.  Completing or quitting a
  campaign now triggers that check itself, right after the moment it lands
  you between campaigns, instead of leaving it to chance.
  Reported by **Spoke**.

- **Fixed: `xset win max/expand` and `min/collapse` didn't do what they were
  documented to.**  Both actually flipped `list_display_mode` — whether the
  target list auto-grows to fit its content or scrolls at a fixed height —
  a real, separate setting already exposed on its own via the right-click
  menu's "Auto-Expand List" entry.  Neither form ever touched the window's
  own height, despite the help text promising a collapse to "its normal and
  minimized state."  `min`/`collapse` now rolls the window up to just
  beneath the tab and TNL bar and remembers the height it was at;
  `max`/`expand` restores it.  A manual drag-resize clears the rolled-up
  state, and both survive a plugin reload.
  Reported by **Crowley**.

- **Fixed: a room-name CP/GQ match could ignore an area's real level range
  entirely, treating it as 1-201.**  Migrating mob or keyword data ahead of
  an area ever being indexed creates a placeholder row for it — just a key
  and a name, to satisfy a foreign key — with no real level data, so the
  database's own default (1-201, wide enough to filter out nothing) is what
  ends up stored.  Those placeholders are marked so a later index could fill
  them in, but `xset index areas` skipped every area whose key already
  existed, placeholder or not — even though the level range it needed was
  sitting right there in the game's own answer to the command it had just
  sent.  It now fills in a placeholder from that answer instead of skipping
  it; a genuinely complete row (from `areas.json`, or an earlier index) is
  still left untouched.  Existing installs: run `xset index areas` once to
  fix any placeholders already sitting in your database.
  Reported by **Obyron**, who had a level 10 campaign for 'the behir' in
  'Cell' come back with Horath — a level 150+ area — listed ahead of New
  Thalos, because every candidate area's stored range was 1-201.

- **Fixed: an express campaign or gquest target routed to the area entrance
  whenever the area had a maze anywhere in it, even nowhere near the
  target.**  The check was "does this area contain a registered maze room",
  not "is the target's own room one" — so a target well before a maze got
  the same fallback treatment as one behind it. Only a target whose own room
  is flagged with `xset maze` is affected now; everything else routes
  straight there as normal.  See `xset maze` and `xset rlink` in `xhelp` for
  how the two work together — `xset rlink` is what to use when a target's
  specific room really is behind a maze and you want it reached directly.
  Reported by **Cephrael**.

- **Fixed: the quest tab could steal focus from an in-progress campaign or
  global quest for no reason.**  Any quest-related GMCP update forced the
  miniwindow to the quest tab — including the ones that are pure background
  bookkeeping, like the quest cooldown timer simply reaching zero again, with
  no action from you.  That now only switches tabs when you are not
  currently mid-campaign or mid-gquest; being on either leaves your tab
  alone.  Reported by **Selitos**.

- **`xcp` now brings the miniwindow tab with it.**  It already retargeted to
  the next campaign or gquest mob after a kill; the visible tab did not
  follow, and could be left showing quest — including from the fix directly
  above.  Every `xcp` navigation now switches to the CP or GQ tab to match
  what it is actually working.  Reported by **Spoke**.

- **`xhelp xg` described the wrong thing.**  It said `xg refresh` redraws
  from memory and `xg reload` resets window layout.  Neither is what the
  aliases actually do: both act on whichever of campaign or gquest is
  running, `refresh` re-sending the check and `reload` the fuller info
  request — real trips to the game, not a local redraw.  Corrected, and
  cross-referenced from the new [R] button below, which is the same
  `reload` action as a click.

- **Fixed: mob names with a hyphen or apostrophe could get a keyword that
  does not include it.**  `half-griffon` could end up with a stored keyword
  of just `griffon`, `y'atora` could lose the apostrophe — and Aardwolf
  treats both characters as literal, so the shortened keyword simply does
  not match.  The keyword guesser itself was already fixed for this a while
  back, but a stored keyword always wins over a fresh guess, so every mob a
  player had already met kept the old, broken keyword regardless.

  On first load of this version, any stored keyword that looks like a fossil
  of the old bug — the mob's name has a hyphen or apostrophe, the stored
  keyword doesn't, and generating it fresh today would produce one that does
  — is corrected automatically, and reported.  Deliberate overrides that
  genuinely omit the character are left alone.  `xset kw fix` repeats the
  same check by hand, for anything set since.

  Reported by **Crowley**.

- **`snd update` reloaded twice.**  Modules and the plugin file are fetched by
  two independent paths, and both reloaded: the module path reloaded as soon as
  the last module landed, and replacing the plugin file reloads on its own.  A
  release that changes both — which is most of them — therefore reloaded twice.

  The visible half was the noise.  The module reload is scheduled a second out
  while the plugin file is still downloading, so it could restart the plugin
  with that download still in flight and lose the new plugin file altogether —
  leaving the version banner offering an update that had, from your side, just
  been installed, on every run.  Now only one path reloads: the modules hand
  theirs to the plugin-file check, which either replaces the file and reloads
  for both, or hands it back.  A module-only update still reloads, including
  when the plugin file cannot be reached.

  Reported by **Crowley**.

- **Fixed: room targets could all come out red, unclickable, and with no
  area.**  Two separate causes, both of which threw away rooms the plugin
  could perfectly well resolve, and both of which showed up as the same
  "unknown location" display.

  The first is a missing level.  The campaign level comes from `cp info` /
  `gq info` and from nowhere else — `cp check` and `gq check` do not carry it
  — so it is unset for a whole campaign whenever that info was never parsed:
  a gquest joined before the plugin loaded, or the first one after installing.
  It was then filtered on as though it were a real level of zero, and since no
  area has a minimum level of zero, every candidate area was rejected and every
  target lost its location.  Refreshing with `gq list` or `gq check` could not
  fix it, because the check is not where the level comes from.  An unknown
  level is now fetched once, the same way an unknown campaign type already
  was; if it still is not available, nothing is ruled out by level rather than
  everything.

  The second is older mapper databases.  The room lookup joined the mapper's
  rooms to its areas table, which required every area to have a row of its
  own — but the area key that join returned was the one already on the room,
  and the area name it fetched was never used, so the join filtered without
  contributing.  Mapper databases carried forward from years of earlier
  plugins do not always have a row for every area they have rooms in, and
  every room in such an area was silently dropped.  The lookup no longer
  consults that table.

  Reported by **Xaade**.

- **`xset import` no longer reads as a failure when it succeeds.**
  Its report ended "0 mark(s) added, 28 skipped", which sounds like 28 things
  it refused.  They were entries already correct — nothing needed importing.
  It now says so in as many words, and says what it covers: area level ranges,
  area start rooms and marks.  Keywords and mob tags are *not* part of it and
  never were; those come across when the database upgrades itself on the first
  run of the new version.  Nothing said so, so a report of having imported
  nothing looked like an answer about keywords when it was not one.

  Reported by **Spoke**, who was trying to bring months of keyword work
  forward.

- **Fixed: a finished gquest's level was applied to the next one.**
  Ending a campaign clears the level it was taken at, from the database as
  well as from memory.  Ending a gquest cleared only the memory copy, so the
  stored value survived — and it is read back on the next reload.  A new
  gquest could then be filtered against a finished one's effective level,
  quietly leaving out areas that were perfectly valid for it.  A stale level
  is worse than a missing one: a missing level is noticed and fetched, while
  a plausible wrong one is used without question.  A finished gquest's target
  list is now cleared too, as a finished campaign's already was.

- **`xcp mode ht` says when it uses `where` instead.**
  On a gquest it has always substituted `where`, because hunt only answers for
  campaign targets.  That is correct, and it has been the behavior since 2021,
  but nothing ever said so — a mode set to `ht` simply did something else, and
  a mode that silently does something else is indistinguishable from one that
  is broken.  It now says so the first time it substitutes in a gquest, once,
  not once per target.

- **A mistyped command no longer writes an error report.**
  Typing an option S&D does not recognize — `xset cols wibble`, `xset nx
  whatever` — was treated as an internal error, which means the whole recent
  trace was written to the debug log.  Guessing at an option name a few times
  produced a file full of trace dumps whose entire contents was the typo, and
  every one of them made a genuine error harder to find in the same file.

  Rejected command arguments now say the same thing, in the same color, and
  are still recorded in the trace — "they typed this, then that broke" is
  exactly the context a dump is for — but no longer trigger one on their own.
  A real failure still writes the trace immediately and unasked, which is the
  point of it: nobody turns debugging on until after the thing they wanted to
  see has happened.  The two are labeled apart in the log.

- **The database upgrade now says how many keywords it moved.**
  It moves them silently, once, unprompted, and that is the only moment they
  cross — so afterwards there was no way to tell "there were none" from "they
  were dropped".  It now reports the count, and reports separately any it
  could not move because the old row had no area recorded.  The old table is
  kept either way.

## New

- **A [R] title-bar button re-fetches CP/GQ info with a click.**  v5 had a
  button for this; v6 only had the typed commands (`xg reload` / `xgui
  reload`).  Shown on the CP and GQ tabs, it acts on whichever one is
  showing — particularly useful on a room GQ, where stale info is easy to
  end up looking at.  Requested by **Selitos**.

- **The quest tab flashes instead of stealing focus.**  A quest event mid-
  campaign or mid-gquest (a new target, a kill, the cooldown becoming ready
  again) no longer switches you away from the CP/GQ tab you're working — see
  the bug fix above — but you should still notice something happened. The
  quest tab now flashes a configurable color (**Quest Ready Flash** in `snd
  settings`, default orange) for about 5 seconds instead, and only when the
  quest tab is not already the one showing.  Switching to it yourself, by
  click or by command, stops the flash immediately.  Requested by
  **Selitos**.

- **`xset kw list [<area>]` — see the keywords you have.**
  There was no way to look at your own keyword overrides.  If you carried some
  forward from an earlier version, nothing could tell you whether they had
  arrived; if a mob was not being found, nothing could tell you what keyword
  was stored for it.  The list is grouped by area, and marks any keyword that
  applies only to the current character along with the shared one it is
  overriding — which is otherwise an unexplainable difference between two
  characters.

- **`xtest portals` — why the mapper walked when you have a portal.**
  S&D does not do its own routing: it hands the destination to `mapper goto`
  and the mapper decides the way, portals included.  So when a portal goes
  unused the answer is in the mapper's data, and this prints it — every portal
  the mapper knows, its level requirement, and whether you clear that at your
  level plus ten per tier.  `xtest portals <area>` narrows it.

- **A loud warning when the whole repository got installed instead of the
  release archive.**  Downloading the repo (`git clone`, or GitHub's green
  *Code → Download ZIP*) and extracting that into the plugins folder is not
  the supported install method, and two people have already had a confusing
  time of it that way — one saw MUSHclient become unresponsive, another saw
  errors that looked like the plugin itself was broken.  On load, the plugin
  now checks for files the release archive never ships (`README.md`,
  `DESIGN.md`, `manifest.json`, `CREDIT.md`) sitting next to it, and if it
  finds any, says so immediately and names the fix — rather than leaving
  someone watching a silent client and guessing.  This cannot repair a bad
  install by itself; there is nothing safe a plugin's own script can do about
  files already sitting beside it before that script has run. But it replaces
  the guessing with a plain answer.

  It is also explicit about the two ways that data is thin: a portal the
  mapper has never watched you use is not recorded at all — an alias of your
  own that holds and enters one teaches it nothing — and a portal whose
  destination room the mapper does not have cannot be routed to.

# v6.0.3

## Bug Fixes

- **Fixed: `xcp mode` did nothing unless the target was an area target.**
  With `xcp mode ht` set, nothing hunted after an `xcp`.  `xcp` takes one of
  three routes depending on the target: straight to a remembered kill room
  (express), to the room the campaign named, or to the area entrance.  Only
  the third ever ran the hunt or the where — and that is the route that needs
  it least.  The other two aim at one specific room, and a room is a guess:
  the mob was killed there once, or the campaign named where it was standing
  when the list was drawn.  When the guess is wrong you arrived, the arrival
  scan reported nothing, and the attempt ended there with nothing looking for
  the mob.  All three routes now honor the setting, including when resuming a
  target after a detour.

  This is what was behind an express jump landing two rooms from a white
  dragon and stopping: the room was right about where the dragon had been,
  and nothing asked where it was now.

  Reported by **Selitos**.

- **Fixed: a pinned room was ignored for room campaigns.**
  `xset mob priority` records "this mob is in *this* room", to settle which of
  several identically-named rooms to walk to.  For a room campaign the target
  was routed by matching the campaign's room name and picking the best-attested
  match, which never consulted the pin — so setting one had no effect at all
  there.  A pin is a deliberate answer and now outranks the ranking; the other
  same-named rooms are still listed for `nx` to cycle through.

- **`xcp` now records which route it took.**
  One debug line naming the branch, area, room ID, room name, whether the
  target is express or pinned, and the current mode.  Walking somewhere
  unexpected previously left nothing behind to say why, and the answer had to
  be reconstructed from the room names in the output.

## New

- **A debug dump now begins with your settings.**
  Most reports come down to "it does this for me and not for you", and the
  usual answer is a setting one of you changed — but the dump recorded what
  happened without ever recording what it was configured to do, so working
  that out took a round of asking.  `snd debug dump` and the header of a debug
  log now list them, and `snd debug settings` shows the same list on screen if
  you would rather paste a dozen lines than send a file.

  Only what you have actually set: a setting still at its default reads the
  same for everyone, so it cannot be the difference, and listing all of them
  would bury the few that can.  Where a per-character value overrides a global
  one both are shown — that is how the same command answers differently on two
  characters.  Colors and fonts are left out.

# v6.0.2

## Bug Fixes

- **Routing now knows which rooms block portals.**
  Every portal destination was treated as one hop from anywhere, which is
  wrong in the rooms that forbid portalling — there the real cost is the walk
  out to somewhere you can use one.  Measured against the mapper from a
  noportal room, the counts were short by a flat 4 hops on eleven of twelve
  targets, which is exactly that walk.  The noportal and norecall flags come
  from the mapper's own database, the same one the routing already reads, so
  this is as accurate as the mapper's data and needs nothing new installed.
  Hop counts now change as you move out of such a room, where before they
  were the same wherever you stood.

  Ordering was already right — a near-constant offset cannot reorder targets,
  and the visiting order matched the mapper's exactly — so this corrects the
  numbers in the Hops column rather than where you get sent.

- **Fixed: the route comparison banned portals on every call.**
  `xtest pathcompare` reported the mapper walking 44 rooms to a destination
  its own `mapper where` reaches in 2, and blamed our routing for the
  difference.  The mapper's `findpath` is asked whether to avoid portals, and
  that answer crosses between plugins as a string — but every string in Lua
  is true, including the empty one, so "no, portals are fine" read as "yes,
  avoid them".  Every measurement taken with it was of the wrong question.
  Ours and the mapper agree exactly where portals are allowed; in a room that
  blocks them ours is short by the walk out, which is 4 hops in the case
  tested, not 44.

- **Fixed: `consider` ignored any line that did not start with the mob.**
  `con all` puts the mob's flags in front of each line, and every consider
  trigger was anchored with no allowance for them — so lines whose wording
  begins with fixed text (`No Problem! ...`) matched nothing at all and were
  printed raw, repeatedly.  Where the wording begins with the mob instead,
  the flag was swallowed into its name, so the same mob was recorded under
  two different names depending on the message.

  Reported by **Obyron**, whose fix this is: capture the flags separately and
  put them back on the front.

- **Consider keeps the mob's colors.**
  The name was reprinted in a flat silver, discarding the coloring the MUD
  sent — which is most of what a consider line tells you at a glance.  The
  flags and the name are now cut out of the line's own styles with
  `TruncateStyles` from the Aardwolf package.

  They are located separately, because they are not always next to each
  other: `A killer bee snickers nervously` puts the name right after the
  flags, but `(G) No Problem! A busy squirrel is weak compared to you` does
  not.  Searching for the two joined found nothing in the second kind, so
  every mob whose message reads that way came out gray while the rest were
  colored — which looked like particular mobs failing rather than particular
  messages.

- **Fixed: `consider` reported on a target that no longer existed.**
  "Consider finished; target not visible here" was decided from a flag that
  only a *scan* ever cleared, so a consider read whatever the last scan had
  left behind — and went on saying it after the mob was killed or the
  campaign ended.  Running `consider all` appeared to fix it only because
  that rewrote the flag.  Each consider now starts from a clean slate, and
  says nothing when there is no target for it to be about.

- **Fixed: `xset kw <keyword>` stored the wrong thing entirely.**
  It set the keyword to something like `*alias2533801`.  The alias called a
  function that takes the keyword as its only argument, but MUSHclient calls
  a script as `(name, line, wildcards)` — so the keyword parameter received
  the alias's own internal name.  The build now fails if any alias handler
  does not take those three arguments.

- **Fixed: scans kept flagging mobs you had already killed.**
  The scan filter matched your campaign list without checking whether an
  entry was still alive, so a completed target went on being tagged and
  sounded on every scan — the scan appeared stuck on the mob you had just
  finished with rather than the one you moved on to.

- **Fixed: `qw` kept asking after it had found the mob.**
  `where <mob>` answers with one line per room, and only the first was
  compared against the target — the rest arrived after the search had already
  finished and been cleared, so each was read as "not the mob", and each sent
  another `where N.mob`.  Hence the trailing run of "There is no N.<mob>
  around here."  Disabling the triggers was not enough on its own: MUSHclient
  had already taken those lines off the socket.  Anything sent past the first
  query is also canceled with `stop`, so the queued ones do not come back
  later.  The hunt trick had the same shape and got the same treatment.

- **Express targets are marked in the miniwindow.**
  They already carried an asterisk in the printed list; the window worked out
  whether a target was express *after* it had drawn the mob column, so the
  mark could never appear on the half people actually watch.

- **`xset mob express` records the room, not just the area.**
  Express means "go to the room rather than the area entrance", so it has to
  know which room — but it only stored the zone the mob was already scoped
  by, and a room ID passed to it was used to look the zone up and then thrown
  away.  It now pins the room you are standing in, or the one you name, and
  clears it again when you turn express off.

  That pin was also never read by anything: `xset mob priority` has been
  storing a room since it was added, and routing carried on using the
  highest-kill guess regardless.  A pinned room is now what the window, the
  hop counts and `xcp` all use.

- **Fixed: `xset express` did nothing at all.**
  The alias captures the state and the kill threshold under one pair of
  names, and the handler read a different one — so `on`, `off` and the
  threshold all fell straight through to the "show current setting" branch,
  reported the unchanged value back, and changed nothing.  Nothing errored,
  which is why it looked like express mode simply not working.

  A check now fails the build if any alias captures something its handler
  never reads, or reads a name nothing supplies.  It immediately found three
  more: `xtest loadroom <room>` ignored the room you named, `xm {mob} <room>`
  accepted a mob and discarded it (that mob is what ranks the results), and
  `xtest simulate gq lose` threw every time it was used.

- **Areas start unrated instead of rated 1.**
  Every area was created with difficulty 1, so a deliberate "easy" could not
  be told apart from an area nobody had ever looked at — and route
  optimization treated the entire unrated map as its top-priority tier.
  Unrated is now 0, shown blank, and `xset area edit <area> difficulty 0`
  clears a rating you no longer want.

  Rating an area also stamps that rating onto every mob there without one of
  its own, so `xset mob tags` reports the number the mob is actually routed
  by rather than a blank you have to resolve against its area yourself.  Mobs
  you rate individually are left alone.

  Existing databases keep whatever is already stored: a 1 written by the old
  default cannot be told from a 1 you chose, so nothing guesses.  Set the
  areas you never rated to 0 if you want them blank.

- **Fixed: `xcp` walked you to the target twice.**
  It looked intermittent because it needs three things at once: `xset autonav
  on`, and a target that is either express or resolves to a single room.
  `xcp` navigates itself, then runs a room search to fill the `nx` list — and
  that search has its own autonav branch, which walks you there when it finds
  exactly one room.  So the display-only search sent you to the room you were
  already being sent to.  A search run purely for display no longer navigates.

  Reported by **Selitos** and **Cephrael**.

- **Fixed: mob tags were ignored for the mob you were actually targeting.**
  `nowhere`, `nohunt` and `noscan` were checked against `current_target.mob`
  and `current_target.arid` — two fields nothing has ever set.  The campaign
  list holds rows shaped `mob`/`arid`, but the current target renames them to
  `name`/`area`, and seven checks had been copied across without renaming.
  Nothing threw, because the lookup simply returned "no tag", so every one of
  those tags silently did nothing in the one case they exist for.

- **Fixed: `xset kw <keyword>` never saw your current target.**
  Same cause: it gated on `current_target.mob`, so it answered "'kw' has no
  current target" no matter what you had targeted.

  Reported by **Cephrael**, after `xcp` onto a barbarian trebuchet.

- **Express targets are marked again.**
  They carry a leading `*` in the target list, as they did in 5.99, with a
  legend under the list.  The destination column already read `Mob ` rather
  than `Area` for them, but nothing said that meant "express".  `xcp` also
  says out loud when it takes an express route, since walking straight to one
  room instead of the area entrance otherwise reads as a routing fault.

- **Fixed: `cp check` after a reload reported an internal error.**
  It answered "build_main_target_list: unknown area_or_room value: none",
  naming a variable no player has reason to have heard of.  The campaign type
  is parsed from `cp info` output and does not survive a reload, so the check
  had nothing to work from.  It now says to run `cp info`, and why.

## New

- **You can choose which columns the target list shows.**
  `xset cols` lists them; `xset cols <column>` flips one, or say `on`/`off`
  outright, in either word order.  `xset cols off` hides every optional column
  at once and `xset cols on` restores them.  They are also in `snd settings`.  Hops, Diff and Type can all be
  turned off — the hop count in particular is dead space if you leave route
  optimization off, since nothing populates it.  The number, mob and
  destination columns stay: without them a row cannot be read or clicked.
  The window itself widens and narrows to match: turning a column on adds room
  for it rather than taking that room out of the mob name, and turning it off
  gives the same pixels back.  Changing the keyword width does the same.  The
  window will not grow past your screen or shrink below its minimum, and a
  width you have dragged to is otherwise left alone.

- **New column: the keyword that would actually be sent.**
  Off by default; `xset cols kw on`.  It shows what `scan`, `hunt` and the
  quick-kill commands will use for each target, so a keyword that does not
  work can be *seen* rather than deduced from a command that quietly finds
  nothing — and corrected on the spot with `xset kw`.  A target with no
  keyword at all reads `(none)` rather than showing blank, since those two
  cases need different fixes.  It is 15 characters wide; `xset cols 20`
  changes that.  The width is in characters rather than a share of the window
  — a keyword is short and does not need more room just because the window
  has it.

- **`cp check` and `gq check` no longer make you run `cp info` first.**
  The campaign type is parsed from `cp info` and does not survive a reload, so
  a check run first had nothing to build from and said so.  It now runs the
  info itself and carries on — the command was never in doubt.

- **Updates now apply themselves, when nothing is in progress.**
  Fetching new modules did nothing until the plugin reloaded, and it left that
  to you — while replacing the plugin file reloaded unasked, which is the more
  disruptive of the two.  A module update now reloads once there is nothing to
  interrupt: no campaign or quest target loaded, no route running, not in
  combat.  Otherwise it says what it is waiting on and leaves the timing to
  you.  `xset autoreload off` restores the old behavior.

  It waits because a reload empties the in-memory campaign state — the target
  list, the current target, the route.  Nothing is lost, since settings, marks,
  keywords and history live in the database.

- **The upgrade from v6.0 no longer needs a manual step.**
  v6.0's plugin file has no way to replace itself, so v6.0.1 had to be
  installed by replacing `Search_and_Destroy.xml` by hand.  Modules do still
  update on a v6.0 install, though, so the upgrade is driven from a module
  instead: `snd update` fetches the new modules, and on the next load one of
  them notices the plugin file is behind, fetches it and reloads.  Everything
  it needs already exists in v6.0's plugin file.  Your database, settings,
  marks and keywords are untouched throughout.

- **`snd version` says when you are on a development build.**
  Versions may now carry a suffix — `6.0.2-dev` — and a pre-release sorts
  *below* the release it leads to, so a tester is not left thinking they are
  current once the real release ships.  The branch an update came from is
  recorded too, since a development branch is not obliged to change its
  version at all and would otherwise be indistinguishable from a release.

- **`xtest pathcompare` compares our routing against the mapper's.**
  Runs both over your current target list and prints the hop counts side by
  side, with the time each took.  It also marks which answers depend on a
  portal: our route seeds every portal destination as one hop from anywhere,
  which is why two runs from different rooms can produce identical counts —
  they are not "distance from you" but "one, plus the distance from the
  nearest portal exit".

# v6.0.1

## Bug Fixes

- **Fixed: `xset nx` could neither show nor change the arrival action.**
  It was two implementations that disagreed.  The bare form printed a global
  nothing ever assigned, so it always showed blank; the form that takes an
  action read the wildcard under the wrong name, so every attempt to set one
  fell through to the "show current" branch and did nothing.  Between them the
  action stayed on its default whatever you typed.  `none` was accepted by the
  command but missing from the list of actions, so it would have been rejected
  too.  One implementation now, and it describes what each option does.

- **Fixed: a crash when killing a campaign mob after `qw <mob>` or `ht <mob>`.**
  Naming a mob directly creates an ad-hoc target, and that target was built
  without a `name` field — so the message printed on killing a campaign mob
  concatenated `nil` and threw.  MUSHclient disables a trigger whose script
  errors, so the CP window then stopped updating for the rest of the session.
  Ad-hoc targets now carry the name you typed, and messages about the current
  target fall back to a label rather than throwing if a field is ever absent.

  Reported by **QuickBen**.

  The same audit found five more places — in `qw`, `scan` and quick-kill —
  where a missing keyword or name would have thrown the same way.  Commands
  that need a keyword now say so and stop, rather than sending a half-formed
  command or taking a trigger down with them.  A test fails the build if any
  target field is ever used somewhere a nil would throw.

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

- **Update messages now name the command.**
  "Reload the plugin to apply updates" left you to work out how; it says
  `snd reload` now.  The same for the message shown when a first-time download
  fails.  The `snd update` help also spells out when a reload is needed at all
  — only when modules changed, since replacing the plugin file reloads by
  itself.

- **Fixed: a run-time error at the end of an update.**
  The plugin checks whether its own file is out of date the instant the module
  downloads finish — which is *before* the new modules have been loaded.  It
  did that by calling a function that lives in `constants.lua`, so on any
  install whose modules predate that function the call hit a nil global and
  threw mid-update.  The plugin file now reads the version constant directly
  and never depends on a module being loaded.

- **`snd force update` no longer discards your edits.**
  It re-downloads every module whether or not it already matches — which is the
  point of it — but it overwrote local edits with no backup at all, while an
  ordinary update always saves a copy before merging.  A file you had edited is
  now saved as `<file>.backup` before being replaced.

- **Removed the beta plumbing.**
  `snd force update beta` was listed in the help, but the branch argument was
  captured and thrown away — the handler never read it.  Along with two
  `betaVersion` / `prevBeta` globals that were only ever `nil` and existed to
  decorate a message.  All gone rather than left looking functional.

- **New: an always-on trace buffer.**
  Debug logging only ever helped if it was already switched on — and it never
  is the first time something goes wrong.  Every debug and error note is now
  kept in a small ring in memory whether or not debug mode is on, costing no
  file writes during ordinary play, and written out when it is worth reading:
  automatically on an error, or on demand with `snd debug dump`.  The log rolls
  over at half a megabyte, keeping one previous generation.

  `snd debug` reports how many notes are held.  For a report where nothing
  errored but the behavior was wrong, `snd debug dump` right afterwards
  captures the run-up.

- **New: `snd dev update`.**
  Pulls modules and the plugin file from a development branch instead of a
  release, so changes can be tested without cutting one.  Always a full
  re-download — a development branch's version does not change between pushes,
  so nothing would look stale — and it says plainly that you are on a
  development build.

- **New: `snd version`.**
  Reports the installed version, the plugin file it is running from, how many
  modules loaded and out of which folder, any module that failed to load, and
  whether the changelog has been shown for this release.  That "which folder"
  line is usually the answer when an update appears not to have taken effect,
  since modules in a developer folder are deliberately never replaced.

- **Fixed: the version was truncated to `6`.**
  MUSHclient stores a plugin's `version` attribute as a *number*, so a
  three-part version like `6.0.1` came back as `6` — which is what the load
  banner showed.  Every comparison against the published `VERSION` therefore
  saw a permanent mismatch, which on its own would have kept the update banner
  up forever and re-fetched the plugin file on every check.

  It is worse than truncation: MUSHclient refuses to load a plugin whose
  version has more than one decimal place at all ("Too many decimal places for
  numeric attribute named 'version'").  So that attribute can only ever carry
  major.minor, and the real version now lives in a string constant that
  everything else compares against.  The release tooling checks the two agree
  and that the attribute is the major.minor of the release.

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
  already update on their own, and your database is untouched.

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
  never be false, so it never ran.  He then caught the first version of this
  fix ordering the candidates by sighting count, which achieved nothing — the
  list is re-sorted by area key afterwards so that every target in one area is
  visited together, and that threw the order away.  Which tier a candidate
  lands in does survive it, so the weaker guesses are deferred rather than
  merely ranked below the stronger one.

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
  unrecognized output would send `hunt N.mob` without limit.  Both now share a
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
  lag, or output whose end tag went unrecognized) left an empty CP/GQ tab with
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
