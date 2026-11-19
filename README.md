# What Caused the Crash

Diagnostic and recovery tool for heavily (or lightly) modded Baldur's Gate 3.

I made this originally because I run a 1300+ mod list. The game prior to this mod had hard lagging or crashing, and I had no idea what had just happened. This mod is the black-box recorder for that situation. It does not magically stop every crash. It tells you what the game was doing right before it died, so you can find the culprit, disable it, or report it properly.

## Main Features

### 1. Crash Journal / Black-Box Recorder

Quietly logs what the engine and mod scripts are doing.

When the game crashes (or freezes and you kill it), open this folder:

```
%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\WhatCausedTheCrash
```

Files you care about:

- `LAST_CRASH_REPORT.txt`: a short summary of the last moments
- `previous_session_journal.txt`: the full journal of the crashed session
- `live_journal.txt`: the current session
- `DANGER_report_1..5.txt`: snapshots taken when the game started struggling, even if it didn't fully crash
- `profile.txt`: which mod scripts were the slowest

#### How to read the journal

- `STALL tick gap 2300 ms` means the game stopped responding for 2.3 seconds. A string of these is trouble.
- `PROFILE busiest handlers just before: [SomeMod/File.lua:123]` means that script was the slowest. It's the prime suspect.
- `PROFILE ... no wrapped handler was busy` means no mod script was running, so the engine itself was stuck. Common causes are base AI trying to choose an action for an NPC with an absurd number of spells (from spell-adding mods), or too many fights running at once.

### 2. Combat Pause (MCM)

- **Pause fights you are not part of.** This helps greatly with game speed.
- **Pause fights as the game loads.** It automatically unpauses on full level load. This reduces the chance of the game crashing on load significantly.

I recommend leaving this on. It helps game speed and noticeably reduces crashes when loading saves that were made in the middle of combat.

### 3. Scene Snapshots / Reconstruction (the big recovery feature)

I made this because I play Honour Mode for the tension. I keep one manual backup outside the save folder in case a bug (not death) bricks the single Honour save.

Sometimes a save loads, plays for a few seconds, then crashes every single time. Scene Snapshots let you take the end state of that scene from the broken save and apply it onto an earlier save of the same area. You continue from where you were instead of replaying hours.

#### How the capture works

The capture is taken the moment the level starts, before whatever later crashes the load. The broken save still loads far enough for the mod to read it.

#### What "Recreate" does

- Moves every captured character back to their exact positions (non-party first, party last).
- Kills whoever was dead, at the correct location, and lets the game run the normal death events (story triggers, loot drops, etc.).
- Restores HP, statuses, inventory, gear, experience, spell slots, cooldowns, short rests, and approval for the party.
- Re-casts summons at their original spots (or re-uses existing ones). Extra summons that weren't there are removed. Spell slots and cooldowns are restored afterward, so it costs nothing.
- Environment: destroys what was destroyed and removes objects that no longer existed.

#### Console commands

Script Extender console. Type `server` first if you're in client mode.

```
!wcc_scenes                  - list captures (* = selected)
!wcc_scene_select 3          - select capture #3
!wcc_scene_apply             - apply the selected capture
!wcc_scene_apply 3           - apply capture #3
!wcc_scene_apply_env         - environment only
!wcc_scene_capture           - capture current scene
!wcc_scenes_window           - open the list in its own window
!wcc_scene_unpause
```

Other useful console commands:

```
wcc                 - snapshot and print journal now
wcc_combats         - list known fights
wcc_freeze / wcc_unfreeze
wcc_prof            - write profiler report
wcc_baseai log|skip|off   - log or force-skip turns of non-enemy NPCs with huge spell lists
```

#### What it cannot copy

- Quest stages, journal entries, dialogue history, and choices.
- Level-up choices (missing XP is added, but you still pick the features).
- Unique items with randomly rolled stats (recreated from the base template).
- Other mods' internal variables.
- Ground surfaces are approximate.
- A chasm is never recreated.
- Characters that were alive at capture stay alive (they may start conversations when moved next to the party).

#### Where captures are stored

```
%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\WhatCausedTheCrash\scenes\
```

## Known Limits

Please read these.

- This is a diagnostic tool first. It points you in the right direction, but it cannot prove which mod is guilty with 100% certainty.
- Pausing a fight also pauses any scripted event inside it. If a quest depends on a background fight finishing while you are away, leave the pause option off, or set it to "only when a warning fires."
- NPCs with massively expanded spell lists (Absolute Laboratory, etc.) can lock the base AI. The journal shows long stalls with "no wrapped handler was busy." `wcc_baseai skip` is a temporary workaround. The better long-term fix is a smarter AI mod.
- Honour Mode has one save slot. The mod handles pause and resume around saves, but always keep a manual backup of your Honour save before first testing the pause option.

## Requirements

- MCM (Mod Configuration Menu)
- Script Extender

## Installation

Put this mod at the very top of your load order, above everything, including MCM. Ignore MCM's warning and tell it not to show again.
