### Changed
- **Kestrel is faster:** its oscillators read their tables four samples at a time and automation reworks only the part of a voice it moves, about a third less CPU on warped and FM patches with no change to the sound.
  - An Osc FM oscillator now follows its modulator's tuning when that tuning is automated or modulated.
