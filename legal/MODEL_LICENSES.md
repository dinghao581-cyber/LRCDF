# Model weights and provenance

LRCDF's source code is licensed under Apache-2.0 (see `../LICENSE`). Model
weights and third-party components can have separate licence conditions. The
weights used in packaged releases are not stored in this source repository.

This document does **not** assign a blanket non-commercial restriction to LRCDF
or assert a training-dataset origin for a release without verifying the actual
weights in that release. A training or experiment script in the source tree does
not, by itself, establish the provenance of the model shipped to users.

## Models and components referenced by the source

| Component | Purpose | Notes |
|---|---|---|
| ToneNet and its ConvNeXt-Tiny backbone | Predict Lightroom develop settings | Project model and torchvision backbone; verify the released weight file and its provenance |
| Retouching, over-retouching critic, and shadow models | Optional retouching and lighting passes | Project model paths appear in the source and packaging scripts; verify which weights a particular release includes |
| MediaPipe models | Face landmarks, pose, and segmentation | Google MediaPipe; check the licence notice accompanying the actual model files |
| OpenCV Zoo SFace | Face descriptors | OpenCV Zoo; verify the model file distributed in the release |
| Additional optional or legacy model integrations | Features enabled when their files are installed | The source contains optional and legacy paths; check whether they are included in the build being distributed |

## Before distributing model weights

1. Inspect the exact release bundle, including optional and legacy model files.
2. Record each model file's publisher, source, training-data provenance where
   applicable, and licence or redistribution permission.
3. Ship any notices and licence texts required for the files actually included.
4. Do not assume the Apache-2.0 source-code licence also licenses third-party
   weights or their training data.

See [third-party software notices](THIRD_PARTY_NOTICES.md) for libraries and
frameworks used by the project. This file is a release-verification checklist,
not a claim that every model or training script in the source tree is shipped
with the app.
