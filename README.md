# ApexCam Pro

A free, offline, no-ads pro camera app for iPhone (iOS 18), built to be **very user-friendly first, pro second**.

- **AUTO by default** — one big shutter button, one-tap presets: Auto, Sports, Portrait, Night, Vlog, Macro, Video
- **PRO mode** — big on-screen dials/sliders for ISO, shutter speed, white balance, EV, manual focus, zoom (0.5×/1×/2×/5×)
- **Subject/motion tracking** — face tracking overlay + tap-to-track, focus follows the subject
- **Video** — best format your phone supports up to 4K60, 24/30/60 fps + slow-mo format picker, stabilization picker (incl. Cinematic Extended when supported)
- **Pro preview tools** — live luminance histogram, rule-of-thirds grid, level, zebra & focus-peaking indicators
- **Dual Save** — like dual card slots: saves to Photos *and* an in-app Vault backup
- **Vlog mode** (front camera, mirrored, countdown), **Rain/Glove mode** (extra-large buttons), **Battery Saver**, volume-button shutter
- 3-screen plain-language onboarding + a "What does it do?" help sheet

Hardware honesty: an app can't add a bigger sensor, a real EVF, a tilting screen, weather sealing, or physical dials — ApexCam uses the software equivalents (your iPhone's built-in sensor-shift stabilization, live exposure preview, on-screen dials, dual-save backup).

## Install (unsigned IPA)
Builds run in GitHub Actions and produce `ApexCam-unsigned.ipa` (unsigned — needs re-signing to install, e.g. Sideloadly on a Mac: put the IPA on the Desktop/Downloads first, not in Messages Attachments). Compile success in CI does **not** prove on-device camera behavior — test on the phone.
