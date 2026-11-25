# Rook's recorded parts

`kit.flac` holds parts of two drum libraries by **Karoryfer Samples**, dedicated to the public domain under
[Creative Commons CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/): **Unruly Drums**
(<https://github.com/sfzinstruments/karoryfer.unruly-drums>, commit 9bf75c2: the kick, the 14" snare, the hi-hat, the
16" crash, the 20" ride and the kick pedal's noise) and **Big Rusty Drums**
(<https://github.com/sfzinstruments/karoryfer.big-rusty-drums>, commit f07ce00: the 14" and 18" toms). Each
repository's `LICENSE` is CC0 1.0 Universal, and Karoryfer's free-samples page says "All our free sample libraries are
under a Creative Commons Zero license" (both read 2026-11-25). CC0 asks for no credit; it is given here with thanks.

Changes made for C.A.W: 36 hits from the close mics, cut to their attacks and short tails (0.15..3.5 s), the drums
high-passed over their heads' lowest modes, faded, folded to mono and normalised per part by
`engine/tools/rook_assets.py`. Rook plays them with its synthesized heads and simulated pieces, so what you hear is not
the original recordings alone. The per-file manifest is in `docs/decisions.md` ("Rook's realistic kit").
