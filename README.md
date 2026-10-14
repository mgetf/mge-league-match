# mge-league-match

`mge_league_match` is a SourceMod plugin for Team Fortress 2. A player runs `!match` on an MGE server. The plugin asks the public mge.tf league API whether that SteamID has an unplayed match in a current season, and says who the opponent is.

If that player is in an arena and every opponent from one of those matches is in the same arena, the plugin locks the arena. Anyone else who tries to join is refused. The players on that match can still rejoin.

## What `!match` does

1. `GET /api/v1/seasons?current=true`
2. `GET /api/v1/matches?player={steam64}&status=unplayed`
3. Keeps matches whose season is in that current set.
4. Prints each pending match: opponent names, week, format, division.
5. Locks the arena only when every opponent is already inside it.

The API does not know who is standing in the arena. That check is local.

## Lock

`MGE_OnPlayerArenaAdd` returns `Plugin_Stop` for a locked arena, unless the joining SteamID is on the match. People already waiting in that arena who are not on the match are removed when the lock starts.

The lock stays up while at least one match player remains in the arena, including the queue. It drops when they all leave, when the map ends, or when the plugin unloads. It does not drop between MGE rounds, so a series can stay in the same arena.

## Whitelist

On lock, the plugin sets `MGE_SetArenaWhitelistOverride`. `mge_whitelist` hears `MGE_OnArenaWhitelistChanged` and applies that list to the players in the arena.

The match payload does not carry a whitelist yet. The plugin still looks for `whitelistId`, `whitelist_id`, or `whitelist` on the match, its season, its format, and its division. The first non-empty value wins. If none of those exist, it uses `mge_league_match_whitelist`. If that cvar is empty too, the arena locks and the player is told that no list was applied.

Clearing the lock clears the override, so the arena cfg whitelist comes back.

## Chat

Player-facing lines live in `translations/mge_league_match.phrases.txt`. English is `en`. Spanish is `es`. SourceMod picks the client's language and falls back to English.

## Cvars

| Cvar | Default | Meaning |
| --- | --- | --- |
| `mge_league_match_api` | `https://mge.tf` | Public API origin. No trailing path. |
| `mge_league_match_whitelist` | empty | whitelist.tf id or slug used when the payload has no whitelist. |

Both land in `cfg/sourcemod/mge_league_match.cfg`.

## Requirements

- Team Fortress 2
- SourceMod with SourcePawn 1.12
- [MGEMod](https://github.com/mgetf/MGEMod) with the arena-add forward and the whitelist override natives
- [REST in Pawn (RIPExt)](https://github.com/ErikMinekus/sm-ripext)
- [mge_whitelist](https://github.com/mgetf/mge-whitelist), if the lock should also restrict weapons

The reads are anonymous. Do not put an API key in this plugin.

## Install

1. Copy `plugins/mge_league_match.smx` to `addons/sourcemod/plugins/`.
2. Copy `translations/mge_league_match.phrases.txt` to `addons/sourcemod/translations/`.
3. RIPExt (`rip.ext`) must already be installed.
4. Set `mge_league_match_whitelist` to the list the league is playing until the API sends one.

## Build

```
spcomp -i"./scripting/include" -i"../MGEMod/addons/sourcemod/scripting/include" scripting/mge_league_match.sp -o plugins/mge_league_match.smx
```

SourcePawn 1.12. The compiler include path for `mge.inc` has to point at MGEMod. The `.smx` is not committed.
