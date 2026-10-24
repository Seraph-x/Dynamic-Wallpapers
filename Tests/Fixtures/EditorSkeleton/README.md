# Independent MDLV0023 fixture

`three-bone.mdl` was assembled directly with Python's standard `struct.pack`,
without calling the JavaScript codec or pinned engine encoder. It is original
test data owned by this repository.

The file contains one 52-byte-stride skinned triangle with joints 0, 1 and 2;
Root / Left / Right bones, with local X translations 0 / -25 / 25; an empty
MDLS tail; a Right-tip attachment referencing bone 2; and an MDLA0006 clip
with two TRS samples per bone. The second X samples are 0 / -25 / 50.
All three scales are 1, rotations are 0 and weights are `(1, 0, 0, 0)`.
The MDLA trailer is 31 zero bytes followed by a zero event count.

The reindex test independently expects joint IDs `(0, 2, 1)`, the attachment
bone ID `1` and second X samples `(0, 50, -25)` when Left and Right swap.
