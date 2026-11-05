# robloxboost
# RobloxBoost

Conservative performance helper for a sideloaded Roblox iOS build. Target: iPhone 14 Pro. **Not compiled or run by me** (no iOS toolchain here), so test one switch at a time.

## Build (no Mac needed)
1. New GitHub repo. Add `RobloxBoost.m` at the top level.
2. Add `build.yml` at `.github/workflows/build.yml` (Add file → Create new file, type that path, paste).
3. Actions tab → "Build RobloxBoost.dylib" → Run workflow → download the `RobloxBoost-dylib` artifact → unzip.
4. If it fails to compile, paste the log to Claude.

Mac one-liner: `xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 -dynamiclib -fobjc-arc -O2 -framework Foundation -framework UIKit -framework QuartzCore -framework Metal -o RobloxBoost.dylib RobloxBoost.m`

## Inject
ESign → your Roblox IPA → Sign → add `RobloxBoost.dylib` as a plugin/dylib → sign and install.
Turn on ESign's file-sharing option to read `Documents/RobloxBoost.log` in the Files app.

## What it does (switches at the top of RobloxBoost.m)
| Switch | Default | Effect |
|---|---|---|
| RB_RENDER_QOS | 1 | Render thread (the one calling nextDrawable) → USER_INTERACTIVE. May be refused on engine-pinned threads (log shows rc). |
| RB_MEMORY_RELIEF | 1 | Returns freed heap pages to the OS on memory warning, on backgrounding, and when headroom < RB_LOW_MEM_MB (700). |
| RB_FRAMERATE_CAP | 120 | If a GlobalBasicSettings_13.xml with a FramerateCap exists, sets it (backup kept). Best effort. 0 = off. |
| RB_METAL_OPAQUE | 0 | Experimental: opaque Metal layer. If you see black where transparency used to be, turn it off. |
| RB_LOG | 1 | Small log, reset each launch. |

## Deliberately NOT touched (RobloxLib already does these)
- Refresh rate + vsync pacing: `AdaptiveSync`, `RBXDisplayRefreshRateObserver`, `presentDrawable:atTime:`, `FrameRateManager`.
- Thermal/battery step-down (`PerformanceControl*`, `RBThermalStateLogger`).
- Metal layer: BGRA8, framebufferOnly=YES, unretained command buffers, drawable count.
Overriding these would fight the engine and can make pacing worse.

## Not possible from a dylib on ESign
- Inline hooks / patching engine code (needs JIT). Engine FPS/graphics flags are internal (not exported), so they can't be set by name.

## Reading the log
- `[env]` screenMaxFPS should be 120 and CADisableMinimumFrameDurationOnPhone should be 1; lowPower=1 caps the display at 60 Hz.
- `[qos] rc=0` boosted; `rc=1` (EPERM) the engine pinned that thread.
- `[metal]` shows what the engine configured.
- `[fps]` says whether the settings file was found.
