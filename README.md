# Search & Destroy

Safe, legal Search & Destroy for Aardwolf — a quality-of-life plugin for
MUSHclient that gets you to your quest, campaign, and global-quest targets
faster.

**Version 6.0** is a ground-up rewrite. If you have used an earlier release,
the commands you know still work; almost everything behind them is new. See
[What's new in v6](#whats-new-in-v6) below, or run `snd changelog` in-game.

---

## What is Search & Destroy?

Search & Destroy is a quality-of-life tool. It uses the mapper plugin to get
you to your quest mobs, campaign targets, and global quest mobs faster. It
loads each target's keyword into an alias, so reaching a mob is a matter of
typing the alias and pressing enter. A tabbed miniwindow shows your quest,
campaign, and global-quest targets side by side, and clicking a target
navigates to it.

It uses its own run-to feature to reach a chosen "start" room for an area. To
be clear about why that is necessary: areas have no inherent start rooms, which
is exactly why the mapper cannot simply run you to an area on request. S&D
lets you nominate one per area and remembers it.

In short, it speeds up your quests, campaigns, and global quests. It is
**not** a bot, whatever anyone tells you. It sends nothing you could not type
yourself, and it never acts without you asking.

---

## Background

Years ago, WinkleWinkle ventured into what some may have considered dangerous
territory and wrote the very first Search & Destroy plugin. Some people hated
it, others loved it. Some people consider(ed) it botting, but it does not break
any rules as-is. Some time after the initial creation, Fiendish made a change
to the mapper database, and it broke WinkleWinkle's Search & Destroy plugin for
many. Nokfah created a fix for it, however, and people were happy once more.

Then WinkleWinkle quit playing, and no more updates happened. Over time, people
had forked his version in efforts of making their own, but one of the greatest
forks happened when Starling got bored and decided to invest time into learning
how it works as well as enhancing it even further. Pwar also created his own
version, and Rauru created a similar version himself. There are probably
several others out there, but none known more than Starling's or Pwar's
versions.

Starling, unfortunately, was banned a while back. In an effort to make sure
that Search & Destroy remained a legal script to use, it was asked that I take
up the maintenance on it. So, here we are today, with further improvements to
be made in the future.

---

## Requirements

* **MUSHclient 4.90 or later**, with the Aardwolf MUSHclient package
  (`aardwolf_colors.lua`, `async`, `movewindow`, and the theme system all come
  from it).

---

## Installing

Download the release archive from the **Releases** page — not the green
*Code → Download ZIP* button, which gives you the whole source tree.

1. Extract the archive into MUSHclient's `plugins` folder. You get
   `Search_and_Destroy.xml` plus a `sounds` and a `snd_modules` folder beside
   it; keep them together.
2. In MUSHclient, choose **File → Plugins → Add** and select
   `Search_and_Destroy.xml`.

That is the whole install. The archive carries everything the plugin needs to
run, so it works straight away. On first load it does fetch two one-time
things — its area data, and a seed script that runs once and deletes itself —
so the first run wants a working connection, but the plugin itself is already
there.

`snd update` replaces modules in `snd_modules` in place, and only the ones that
actually changed.

You do not need to clone this repository. In particular, do not copy the `lua`
folder into your plugins directory: it is the development checkout, the plugin
ignores it unless it contains a `.dev` marker, and its module names are generic
enough to collide with scripts of your own. The plugin says so on load if it
finds modules there.

Your data lives in `SnDdb.db`, alongside the mapper's own database. The mapper
database is only ever read, never written.

---

## Getting started

Run **`xhelp`** in-game. It opens a browsable, clickable index of every
command, grouped by category, with per-subcommand entries and full-text search
(`xhelp <anything>` falls through to a content search when no topic matches).

Everything below is documented there in more detail.

### The commands you will use most

| Command | What it does |
|---|---|
| `cp info` / `gq info` | Load campaign or global-quest targets into the window |
| `cp check` / `gq check` | Run `campaign check` / `gquest check` |
| `xcp` | Navigate to a campaign or gquest target by index |
| `xq` | Reload and display current quest information |
| `xqt` | Retarget the current quest mob (e.g. after using `xcp` or `qw`) |
| `go` | Jump to a specific room in the current search results by index |
| `nx` | Step to the next or previous room in the current search results |
| `xrt <area>` | Run to the start room of an area by keyword |
| `qw` | Send `where` for your current target or a named mob |
| `ht` | Perform the "hunt trick" for your current target or a named mob |
| `xw <mob>` | Send a series of `where N.mob` commands to find every instance |
| `kk` / `ak` / `qk` | Set or execute a quick-kill sequence on your current target |

### Teaching it about the world

S&D gets better the more you tell it. All of this is per-character and
persistent.

| Command | What it does |
|---|---|
| `xset mark` | Save named room shortcuts, used by `xrt` for navigation |
| `xset area list` | List areas you have added, or areas still missing a start room |
| `xset area edit <key> ...` | Set an area's start room, level range, or difficulty |
| `xset mob <flag> <mob>` | Tag a mob: hide it, skip hunting it, pin its room, rate it |
| `xset mob express <mob>` | Skip the area start room for a mob you reliably find in one room |
| `xset kw <keyword>` | Override a mob's target keyword when the default does not work |

### Settings and housekeeping

| Command | What it does |
|---|---|
| `snd settings` | Open the point-and-click settings window |
| `xset win` | Show, hide, resize, or reset the miniwindow |
| `xset pathing` | Control campaign route optimization and express mob ordering |
| `snd stats` | Per-level stats, a daily summary, or area kill counts |
| `snd changelog` | See what changed since your version, or the full history |
| `snd update` | Update to the latest version |

---

## What's new in v6

v6.0 is not a feature patch on the earlier releases — it is a ground-up
rewrite. The original was a single monolithic XML file with all logic inline;
v6 is a multi-file plugin with the code split into focused modules that the
plugin downloads and loads on demand.

The changes users notice most:

* **Route optimization.** A travelling-salesman solver plans the order to visit
  your campaign targets in, using real room-distance data from the mapper
  rather than guessing. You can rate areas — and individual mobs — by how
  awkward they are to *reach*, and the route respects that.
* **A themed, tabbed miniwindow.** Quest, campaign, and global-quest targets
  each get a tab. It follows the Aardwolf package's colour scheme and
  participates in the layout-lock and z-order systems.
* **Everything persists in a database.** Marks, area records, mob flags,
  keywords, campaign history and per-level statistics live in `SnDdb.db`
  instead of scattered client variables, per character.
* **Campaign and quest history**, with per-level statistics and predictions
  based on your own past runs.
* **A real help system.** `xhelp` is a structured, searchable, hyperlinked
  topic browser rather than a wall of text.
* **Smart updates.** `snd update` fetches only the modules that actually
  changed, and keeps local edits you have made where upstream has not touched
  the same code.

For the full list — every feature, every fix — run `snd changelog` in-game or
read [changelog.md](changelog.md).

---

## Updating

Run **`snd update`**. It checks for a newer version, downloads only what
changed, and tells you what it did.

The first time you load a new version, S&D shows you what changed since the one
you were running. `snd changelog` does the same on demand, `snd changelog all`
shows the complete history, and `snd changelog since <version>` shows a
specific range.

---

## Credits

WinkleWinkle wrote the original. Nokfah kept it alive through a mapper change.
Starling's fork is the direct ancestor of this one. Pwar and Rauru wrote their
own versions along the way.

Sound effects obtained from [zapsplat](https://www.zapsplat.com).

Maintained by **Crowley**.
