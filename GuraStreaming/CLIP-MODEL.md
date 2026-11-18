# Thumbnail candidate model

`GuraStreaming/Models/clip-image.mlpackage` is the 8-bit palettized image encoder
from [veszelovszki/cmdr-clip-vit-b32-coreml](https://huggingface.co/veszelovszki/cmdr-clip-vit-b32-coreml),
a Core ML conversion of OpenAI CLIP ViT-B/32. The original model is MIT licensed;
see `CLIP-LICENSE.txt`.
The model package is git-ignored. From the repository root, run
`GuraStreaming/Tools/download-clip-image-model` before building the app. The
command downloads and verifies the pinned image model.

`Tools/clip-labels.json` is the user-edited source of the positive and negative
descriptions. Copy `Tools/clip-labels.example.json` to create it on a new
checkout. The generated `GuraStreaming/clip-prompts.json` holds those labels
and their 512-dimensional, L2-normalized text embeddings. Both files are
git-ignored. The vectors use the matching Core ML text encoder from the same
repository and the standard CLIP BPE tokenizer. The text encoder is not bundled
with the app.

To change the descriptions, edit the `positivePrompts` and `negativePrompts`
arrays in `Tools/clip-labels.json`, then run this from the repository root:

```sh
GuraStreaming/Tools/regenerate-clip-prompts
```

The command writes `GuraStreaming/clip-prompts.json`. Its first run downloads
the matching text encoder (about 175 MB) into the ignored `GuraStreaming/Tools/.cache`
directory. Later runs reuse that copy. The command also downloads the CLIP
vocabulary and merge table into the git-ignored `Tools/clip-vocab.json` and
`Tools/clip-merges.txt` when they are missing. It checks pinned downloads'
SHA-256 values and rejects empty prompts or prompts beyond CLIP's 75-token
limit. Both tokenizer files come from `openai/clip-vit-base-patch32`.

The image input is a center-cropped 224 × 224 RGB tensor, normalized by the
standard CLIP channel means `(0.48145466, 0.4578275, 0.40821073)` and standard
deviations `(0.26862954, 0.26130258, 0.27577711)`. Core ML is configured with
`.cpuAndNeuralEngine`; prediction runs on a background queue at most once per
five seconds while recording.

Each saved candidate appears in `log.csv` with its video timestamp and JPEG path,
the highest positive and negative cosine similarity scores, the description
matched by each score, and `score_margin` (positive minus negative). A candidate
is saved when the margin is greater than zero. Scores describe relative model
similarity; they are not probabilities.
The `top_1`–`top_5` columns list the five highest scores across both groups;
`bottom_1`–`bottom_5` list the five lowest, starting with the lowest. Each cell
contains the group, prompt text, and cosine score.
