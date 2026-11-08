# ApexCam Pro

A free, offline, no-ads pro camera app for iPhone (iOS 18), built to be **very user-friendly first, pro second**.

## NEW in v4 — LUTs for photos ("the photo version of Blackmagic Camera")
- **LUT engine for PHOTOS** — the Blackmagic LUT workflow, but for stills: pick a look, see it live on the preview, and the **graded photo is what saves** (baked in, like Blackmagic's *Record LUT to Clip*)
- **Import your own `.cube` LUTs** from Files (17/32/33/64-point, parsed in-app) — they persist in the app's Documents and stay in the LUT picker across launches
- **Built-in looks generated in code** (no borrowed files): Warm Golden Hour (the default), Teal & Orange, Kodak Film, Soft Portrait, Classic B&W — rendered to 32-point cubes through `CIColorCube`
- **Strength slider 0–100%** and an *Apply LUT to saved photo* toggle (ON by default), applied at capture time on a background queue
- **Default launch mode is All-Day Sports**: 1/1600 fast-shutter priority, auto focus/ISO, −0.3 exposure bias, Warm Golden Hour LUT selected — one tap, all day, especially sports
- Honest labelling: **LUTs apply to photos only** — video records without a LUT rather than faking it

- **AUTO by default** — one big shutter button, one-tap presets: All-Day, Auto, Sports, Portrait, Night, Vlog, Macro, Video
- **PRO mode** — big on-screen dials/sliders for ISO, shutter speed, white balance, EV, manual focus, zoom (0.5×/1×/2×/5×)
- **Subject/motion tracking** — face tracking overlay + tap-to-track, focus follows the subject
- **Video** — best format your phone supports up to 4K60, 24/30/60 fps + slow-mo format picker, stabilization picker (incl. Cinematic Extended when supported)
- **Pro preview tools** — live luminance histogram, rule-of-thirds grid, level, zebra & focus-peaking indicators
- **Dual Save** — like dual card slots: saves to Photos *and* an in-app Vault backup
- **Vlog mode** (front camera, mirrored, countdown), **Rain/Glove mode** (extra-large buttons), **Battery Saver**, volume-button shutter
- 3-screen plain-language onboarding + a "What does it do?" help sheet

Hardware honesty: an app can't add a bigger sensor, a real EVF, a tilting screen, weather sealing, or physical dials — ApexCam uses the software equivalents (your iPhone's built-in sensor-shift stabilization, live exposure preview, on-screen dials, dual-save backup).

## Magic Tools — only in ApexCam
Motion-trigger Auto-Capture, Smile/Face Auto Shutter, Clap/Sound Shutter, Vlog Teleprompter, Timelapse + Stop-Motion (onion skin), Face ID Private Vault, built-in Edit Studio (CoreImage filters + brightness/contrast), rule-based on-device Coach Tips, approximate Golden Hour badge, and GPS EXIF Location Stamp. All off by default except Coach Tips, all under **Tools > Magic Tools** with plain-English explanations.

## Install (unsigned IPA)
Builds run in GitHub Actions and produce `ApexCam-unsigned.ipa` (unsigned — needs re-signing to install, e.g. Sideloadly on a Mac: put the IPA on the Desktop/Downloads first, not in Messages Attachments). Compile success in CI does **not** prove on-device camera behavior — test on the phone.
