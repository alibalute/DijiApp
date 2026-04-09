Bundled MIDI library (Playback tab → "MIDI library")

1. Add .mid / .midi files under this folder (any subfolders you like).
2. Edit midi_manifest.json: add "dir" and "file" entries. Each file must list the
   exact Flutter asset key, e.g. "assets/midi_library/MyFolder/song.mid".
3. Run flutter pub get / build so new assets are included.

The in-app browser reads midi_manifest.json only; it does not auto-scan the filesystem.
