# Logo generator

`gen.py` writes `assets/{logo,icon}-{light,dark}.svg`: the same 4×5 core-grid "B" mark as BloxMiner's logo,
with one amber "hot core", plus the "Blox" + "Miner" + "-X" wordmark converted to outlines (no font needed
to view it). The "-X" suffix is set in the hot-core amber so the mark reads as BloxMiner-X's own, not a
relabelled BloxMiner logo.

    python3 -m venv venv && ./venv/bin/pip install fonttools
    # Inter 4.1 (SIL Open Font License 1.1): https://github.com/rsms/inter/releases/tag/v4.1
    cd ../../assets && ../tools/logo/venv/bin/python ../tools/logo/gen.py /path/to/InterDisplay-Bold.ttf

Font file used: `extras/ttf/InterDisplay-Bold.ttf` sha256 `b74c8e0dd744b3347faca4c96bc7b2e32f7d6f62300a79b1d1a99331e44a5bc4`
(same file as BloxMiner's logo tool; identical hash confirms it's the same Inter 4.1 release).

Wordmark outlines are derived from Inter Display Bold, © The Inter Project Authors, SIL OFL 1.1.
