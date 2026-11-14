# Model weights and training data

LRCDF's **source code** is Apache-2.0. The **trained weights** it uses are a
separate matter: each was trained on, or comes from, material with its own
terms. **This repository does not contain any model weights.** The project's own
trained weights (ToneNet, the retouch, critic and shadow models) are not published for now; their
terms will be announced here if and when they are. Third-party weights (MediaPipe,
SFace, and so on) are fetched from their original publishers. Read this before
redistributing any weights or using LRCDF commercially.

| Model (file) | What it does | Origin / training data | Terms |
|---|---|---|---|
| ToneNet (`runs/tone/tone.pt`) | Predicts Lightroom develop settings | Trained by this project on PPR10K (portrait photos with expert retouching); starts from torchvision ConvNeXt-Tiny ImageNet weights | Derived from PPR10K: research / non-commercial terms of that dataset apply to the weights |
| Retouch model (`runs/retouch_model.pt`) | Blemish pass on large faces | Trained by this project on FFHQR (retouched FFHQ faces) | FFHQR is CC BY-NC-SA: the weights are non-commercial, share-alike, with attribution |
| Over-retouching critic (`runs/critic_model.pt`) | Tells when a face was changed more than professionals would; picks the automatic level | Trained by this project on measurements of FFHQ / FFHQR pairs; starts from torchvision ResNet-18 ImageNet weights | Derived from FFHQR (CC BY-NC-SA) and FFHQ: non-commercial, share-alike, with attribution |
| Cast-shadow model (`runs/shadow_model.pt`) | Removes shadows thrown onto faces (part of "even light") | Trained by this project on FFHQ faces with synthetic shadows | Derived from FFHQ (dataset CC BY-NC-SA 4.0 by NVIDIA; images under their authors' Creative Commons licences): non-commercial |
| Dodge-and-burn model (`runs/dodge_model.pt`, experimental, not used by default) | Alternative blemish pass | Trained by this project on FFHQR with synthetic blemishes | As the retouch model: non-commercial, share-alike, with attribution |
| RetouchFormer (`gen_best.pth`) | Blemish pass on small faces | RetouchFormer (AAAI 2024) authors' released weights, trained on FFHQR | Non-commercial (FFHQR); see the RetouchFormer project for its code terms |
| RetinaFace ResNet50 | Face detector | ModelScope skin-retouching package (RetinaFace implementation under MIT, trained on WIDER FACE) | Code: MIT / Apache-2.0; training data: research terms |
| MediaPipe face landmarker, pose landmarker, selfie multiclass segmenter | Face mesh, body pose, skin/hair/clothes masks | Google MediaPipe model files | Apache-2.0 |
| SFace (`face_recognition_sface_2021dec.onnx`) | Face descriptor for per-person settings | OpenCV Zoo | Apache-2.0 |
| Age/sex estimator (`models/agegender/model.onnx`) | Picks a gentler default level for men and children | Vision Transformer fine-tuned on UTKFace | Weights licensed Apache-2.0 by their publisher; UTKFace itself is for non-commercial research |

## What this means for you

- **Using LRCDF yourself** (personal, study, non-commercial open-source use):
  fine.
- **Selling LRCDF, offering it as a paid service, or using it in a commercial
  workflow** is *not* covered while these weights are included. Either replace
  them with weights you trained on data you may use commercially, or obtain
  permission from the data owners.
- **Redistributing weights**: keep this file with them, keep the attribution
  below, and share them only under terms no more permissive than the
  non-commercial terms above (CC BY-NC-SA 4.0 for weights trained on FFHQR).
  The project's own weights are unpublished for now, so there is nothing to
  redistribute yet.
- Photos you retouch belong to you; the licences above do not apply to your
  output images.

## Attribution

- **PPR10K**: Liang et al., "PPR10K: A Large-Scale Portrait Photo Retouching
  Dataset with Human-Region Mask and Group-Level Consistency", CVPR 2021.
- **FFHQ**: Karras, Laine, Aila, "A Style-Based Generator Architecture for
  Generative Adversarial Networks", CVPR 2019 (images from Flickr under Creative
  Commons licences chosen by their authors).
- **FFHQR**: Shafaei et al., "AutoRetouch: Automatic Professional Face Retouching",
  WACV 2021, University of British Columbia (CC BY-NC-SA).
- **RetouchFormer**: Xie et al., AAAI 2024.
- **MediaPipe**: Google LLC (Apache-2.0). **OpenCV Zoo SFace**: OpenCV
  contributors (Apache-2.0).
- **UTKFace**: Zhang, Song, Qi, CVPR 2017.
