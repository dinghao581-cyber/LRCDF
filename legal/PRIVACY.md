# Privacy Policy

Last updated: 2026-11-14 · Applies to LRCDF (the Lightroom Classic plug-in, the
companion desktop app and the command-line tools).

## In short

LRCDF runs entirely on your own Mac. It does not collect, upload, sell or share
your photos, faces or any personal information. It has no accounts, no
analytics, no telemetry and no crash reporting.

## What LRCDF processes

- **Your photos.** Lightroom exports previews or full-resolution copies of the
  photos you choose; LRCDF's local programs read them, compute the edit, and
  write the result back (develop settings in your catalog, or a new
  `<name>-LRCDF.tif` file next to the original).
- **Faces in those photos.** To retouch faces, LRCDF runs face detection,
  landmark detection, segmentation and a local age/sex estimate on your Mac.
  If a photo contains several people, it also computes a numeric face
  descriptor for each clearly seen face, so that the same person can be given
  the same retouching level across photos.

None of this leaves your computer. The software contains no code that sends
data over a network while you use it.

## What LRCDF stores on your Mac

Everything is stored in `~/Library/Application Support/LRCDF` and in the folders
you choose:

| Data | Why | Contains personal data? |
|---|---|---|
| `previews/`, `thumbs/`, `before/` | Pictures shown in the app | Yes (your photos) |
| `known_people.json`, `people.json`, `person_*.jpg` | Remember per-person retouching choices | Yes (face descriptors and face crops; biometric in nature) |
| `my_styles.json`, `session.json`, `run.json`, `progress.txt`, `cmd/`, `beauty_server/` | Your looks, the current job and progress | Photo ids and file paths |
| macOS preferences (`com.ding.lrcdf.app`) | Two on/off settings: hide the launch notice, break reminder | No |
| `<name>-LRCDF.tif` | The retouched result | Yes (your photo) |

LRCDF never deletes your original files. You can remove all of LRCDF's stored
data at any time by deleting the `LRCDF` folder above (and the `-LRCDF.tif`
files you no longer want). Face descriptors are not exported or shared by the
software.

## Network use

- While running, LRCDF makes **no network connections**.
- Installing LRCDF may download the software itself, its dependencies (for
  example Python packages) and its model files from the servers of the project's
  release page, your package manager or the model publishers. Those downloads are governed by the privacy policies of those
  services, not by LRCDF, and carry no photo data.
- If a future version adds an update check, it will be off by default or clearly
  announced, will send no photos or personal information, and this policy will
  be updated first.

## Children, biometric and sensitive data

LRCDF does not target children and does not collect personal data from anyone.
Because it can analyse faces, you are responsible for having the right to
process the photos you give it, including consent of the people shown where
the law of your country requires it (for example under the GDPR or similar
laws). The age/sex estimate is used only to choose a gentler default retouching
level and is not stored as a record about a person.

## Third-party software

Lightroom Classic is a product of Adobe and is governed by Adobe's own privacy
policy. LRCDF uses Lightroom's plug-in interface to read and write develop
settings and to export and import files, locally.

## Changes and contact

Changes are published in this repository with a new "Last updated" date. Questions or
requests: open an issue at https://github.com/dinghao581-cyber/LRCDF. LRCDF holds no data about you, so there
is nothing to access or delete on our side.
