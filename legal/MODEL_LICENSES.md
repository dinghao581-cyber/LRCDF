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
| MediaPipe Pose Landmarker (BlazePose GHUM 3D; `pose_landmarker_heavy.task` in the plug-in; `pose_landmarker_full.task` (float16, 9,398,198 bytes, SHA-256 `5134a3aa…11b1`) in Tonewell for Windows) | Find body landmarks for shaping | Google MediaPipe model; its model card states it is licensed under the Apache License 2.0 and that surveillance or identity recognition is out of scope; check the licence notice accompanying the exact file shipped |
| Tonewell: FaceMesh and Blendshapes (Core ML) | Detect closed eyes | The face-landmarks detector and face-blendshapes networks of Google's MediaPipe Face Landmarker (`face_landmarker.task`, Apache-2.0), converted by this project to Core ML; check the licence notice accompanying the original model file |
| Tonewell: FaceEmbed (Core ML) | Recognise the same person across a batch (per-person settings) | OpenCV Zoo SFace (`face_recognition_sface_2021dec`, Apache-2.0), converted to Core ML; check the licence of the original file |
| RetinaFace face detector (`retinaface_resnet50_2020-07-20_old_torch.pth`, also Core ML `RetinaFace` in Tonewell) | Find faces | ResNet-50 RetinaFace checkpoint of the ternaus/retinaface project (MIT, Copyright (c) 2020 Vladimir Iglovikov), itself built on biubug6/Pytorch_Retinaface (MIT); the file reaches us through the ModelScope skin-retouching model package (Apache-2.0). The upstream project trains face detection on WIDER FACE-style labels; the dataset's own terms and the exact training data of this checkpoint have not been independently confirmed. Licence texts: `licenses/RETINAFACE_ternaus_LICENSE.txt`, `licenses/PYTORCH_RETINAFACE_biubug6_LICENSE.txt` |
| Make-up and skin-depth scorer (`makeup_s2.pt`, Core ML `Makeup`) | Tell whether a face wears make-up and judge skin depth, so make-up is kept and dark skin keeps its depth | Exported from Apple's MobileCLIP2-S2 image encoder (open_clip `dfndr2b`) by `scripts/export_makeup.py`, with the text directions baked in. **This file is a Model Derivative of an Apple Machine Learning Research Model, modified by this project** (only the image encoder is used; it is re-parameterised, the "face wearing make-up" and "dark skin" text directions are baked in, the weights are converted to half precision and traced to TorchScript, and for Tonewell also converted to Core ML), and is distributed under the Apple Machine Learning Research Model License Agreement (`apple-amlr`); its text is in `licenses/APPLE_ML_RESEARCH_MODEL_LICENSE.txt` and ships with every package that contains the model. Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement. That agreement has its own terms for use and redistribution; read it before reusing this file. Apple's name and marks are not used to endorse LRCDF or Tonewell |
| Age/sex model (ViT; `models/agegender/model.onnx`, quantised to `AgeSex_int8` Core ML / ONNX for Tonewell) | Estimate age and sex to start children and men at the lightest retouch level, and as a safeguard for "Fuller bust" (blocks people read as under 18 and people read as men; it does not confirm that anyone is an adult) | ONNX conversion (`onnx-community/age-gender-prediction-ONNX`, Apache-2.0) of `abhilash88/age-gender-prediction` by Abhilash Sahoo (Apache-2.0), a fine-tune of `google/vit-base-patch16-224` (Apache-2.0) on the UTKFace dataset (23,687 images, per the model card). The file in use is byte-identical to the ONNX repo's `onnx/model.onnx` (SHA-256 `0c35c868…8304`); Tonewell packages are a quantised/converted modification of it. Apache-2.0 text: `../LICENSE`. Offered as a download in Tonewell Mac/iPad 0.3; included in Tonewell for Windows |
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
