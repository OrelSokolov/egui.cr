# AGENTS.md

## Verification of GUI changes

If a change to egui.cr (widgets, overlays, animations, anything visual)
is faster to verify by eye than by script — ask the user to check it.
Do not write verification scripts, do not burn tokens on pixel-diff
screenshot pipelines. The user can look at the window and tell you in
seconds whether it works.
