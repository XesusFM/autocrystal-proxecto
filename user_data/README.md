# Route Campaign runtime data

AutoCrystal creates campaign profiles, progress files, temporary files, and
recovery backups in this directory. They are local runtime state and are
ignored by Git.

Do not edit a profile while Route Campaign is running. Use the campaign editor
inside the launcher. If a primary file is incomplete after an interrupted
write, AutoCrystal attempts to load its `.bak` file automatically.
