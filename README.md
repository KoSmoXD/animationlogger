# Animation Logger

Standalone Roblox client-side animation logger for **player characters and NPCs**.

## Features

- Records `Animator.AnimationPlayed` events from characters visible to your client.
- Picks up animations already playing when recording begins.
- Shows the **published Roblox animation asset name** (when available) using cached asynchronous asset lookups; falls back to the local animation/track name for private, deleted, or inaccessible assets.
- Logs character name, type (**Players** / **NPCs**), animation name, animation asset ID, timestamp and whether it was already playing.
- Includes **All / Players / NPCs** filters and a search box.
- **Copy Name**, **Copy ID**, **Copy All**, **Clear**, **Pause / Start**, and **Save .txt** (where supported).
- Draggable window for desktop and touch devices.
- Bounded 300-event history and 70 visible rows; no per-frame scanning.
- Re-executing the script closes the previous logger instance.

## Run

Use a client-side Lua environment that supports `game:HttpGet` and `loadstring`:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/KoSmoXD/animationlogger/main/AnimationLogger.lua"))()
```

Alternatively, copy `AnimationLogger.lua` into an appropriate client-side environment. This is a standalone script, **not** an update to Mr H Reanimate.

## Limitations

- Only animations observable by your Roblox client can be logged. Server-only and unreplicated tracks are not accessible.
- The `Copy` actions need `setclipboard`; when it is unavailable, the selected text is placed in the search input for manual copying.
- **Save .txt** requires `writefile` support from your environment.
- Recording captures animation *play events*, not animation source/keyframes, and it does not circumvent asset permissions.
- Some animations use empty or unavailable IDs and will be displayed as `Unknown ID`.
- Published names are fetched asynchronously through Roblox MarketplaceService; lookups can fail or be throttled, so the original animation name is shown as a fallback.

## Usage

Run the script, play or observe character animations, then press **Copy Name** or **Copy ID** beside a record. Use the filter and search controls to narrow the results. Click **X** to cleanly disconnect listeners and close the GUI.
