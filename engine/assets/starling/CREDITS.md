# Starling's recorded parts

`piano.flac` holds parts of the **Salamander Grand Piano V3** by Alexander Holm (a Yamaha C5), licensed under the
[Creative Commons Attribution 3.0 Unported licence](https://creativecommons.org/licenses/by/3.0/)
(source: <https://github.com/sfzinstruments/SalamanderGrandPiano>, read 2026-11-24).

Changes made for C.A.W: the first 200 ms of 120 notes (30 keys, 4 velocity layers), 22 key-release noises and 4 pedal
noises, trimmed, faded, folded to mono and normalised per clip by `engine/tools/starling_piano_assets.py`. Starling
plays them with its modelled strings, so what you hear is not the original recordings alone.

`guitar.flac` holds parts of FreePats' **Spanish Classical Guitar** (2019-06-18) by Roberto (roberto@zenvoid.org) for
the FreePats project, dedicated to the public domain under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)
(source: <https://freepats.zenvoid.org/Guitar/acoustic-guitar.html>, read 2026-11-25). `harp.flac` holds parts of the
concert harp of the **Versilian Community Sample Library** (VCSL) by Versilian Studios LLC, also CC0 1.0 (source:
<https://github.com/sgossner/VCSL>). No credit is required; it is given with thanks.

Changes made for C.A.W: the first 134 ms (the harp's 149 ms) of 16 guitar notes and 46 harp notes, trimmed, faded,
folded to mono and normalised per clip, with each clip's first 30 ms (45 ms) again with the estimated body taken off,
by `engine/tools/starling_strings_assets.py`. Starling plays them with its modelled strings.
