# Bittern's recorded parts

`speech.flac` holds parts of the pipe organ in the **Versilian Community Sample Library** (VCSL) by Versilian Studios
LLC, dedicated to the public domain under [Creative Commons CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)
(source: <https://github.com/sgossner/VCSL>, read 2026-11-25: the `Aerophones/Edge-blown Aerophones/Pipe Organ`
folder). Its `Info.txt`: "Organ sampled by Simon Dalzell of Ivy Audio, Winter 2015-16. Bearer is granted right to
redistribute this sample set by Versilian Studios LLC. Credit to both original author and Versilian Studios is
encouraged." Credit is given here with thanks.

Changes made for C.A.W: of 64 notes (the Quiet, Loud, Quiet Pedal and Loud Pedal registrations), the first 400 ms of
what each holds beyond its harmonics' envelopes (the pipes' speech noise, less the steady part), faded, folded to mono
and normalised per clip by `engine/tools/bittern_assets.py`, which also measures the pipes' spectra, speech, wander and
noise from them. Bittern plays them with its modelled pipes, so what you hear is not the original recordings. The
per-file manifest is in `docs/decisions.md` ("Bittern").
