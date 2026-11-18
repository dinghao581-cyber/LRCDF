# Privacy Policy

Last updated: 2026-11-16 · Applies to LRCDF on every platform it
runs on: macOS, Windows and iPad (the Lightroom Classic plug-in, the companion
app, the iPad app and the command-line tools).

## In short

LRCDF runs entirely on your own device (Mac, Windows PC or iPad). It does not collect, upload, sell or share
your photos, faces or any personal information. It has no accounts, no
analytics, no telemetry and no crash reporting.

## What LRCDF processes

- **Your photos.** Lightroom exports previews or full-resolution copies of the
  photos you choose; LRCDF's local programs read them, compute the edit, and
  write the result back (develop settings in your catalog, or a new
  `<name>-LRCDF.tif` file next to the original).
- **Faces in those photos.** To retouch faces, LRCDF runs face detection,
  landmark detection, segmentation and a local age/sex estimate on your device.
  If a photo contains several people, it also computes a numeric face
  descriptor for each clearly seen face, so that the same person can be given
  the same retouching level across photos.

None of this leaves your computer. The only outgoing network use is the update
check described under "Network use" below; it sends no photos or personal
information.

## What LRCDF stores on your device

Everything is stored in LRCDF's own data folder and in the folders you choose.
On a Mac that is `~/Library/Application Support/LRCDF`; on Windows it is
`%APPDATA%\LRCDF`. On an iPad, photos you import are copied to the app's
temporary folder (`imports/`, results in `exports/`), which the app clears at
start-up and from its "clear" button; downloaded model updates are kept in the
app's Application Support folder; and the app's Documents folder is visible in
the Files app, where you can put photos yourself. The iPad app saves a result
to your Photos library only when you tap the save button. The table below
describes the Mac and Windows versions; the iPad app differs as noted under it.

| Data | Why | Contains personal data? |
|---|---|---|
| `previews/`, `thumbs/`, `before/` | Pictures shown in the app | Yes (your photos) |
| `known_people.json`, `people.json`, `person_*.jpg` | Remember per-person retouching choices | Yes (face descriptors and face crops; biometric in nature) |
| `my_styles.json`, `session.json`, `run.json`, `progress.txt`, `cmd/`, `beauty_server/` | Your looks, the current job and progress | Photo ids and file paths |
| App preferences (on a Mac, `com.ding.lrcdf.app`) | Two on/off settings: hide the launch notice, break reminder; also the automatic-update switch | No |
| `<name>-LRCDF.tif` | The retouched result | Yes (your photo) |

LRCDF never deletes your original files. You can remove all of LRCDF's stored
data at any time by deleting that data folder (on an iPad, by deleting the app) (and the `-LRCDF.tif`
files you no longer want). Face descriptors are not exported or shared by the
software.

To avoid erasing makeup, every version (Mac, Windows and iPad) runs a
"is this face wearing makeup" check on each face crop. It turns the image into
a feature score in memory, has nothing to do with identity, and the result is
not saved. On the iPad, faces, landmarks, skin maps, body pose and portrait
masks likewise exist only in memory and are never written to disk.

On the iPad, for each photo that has a face at least 100 px wide, the same
on-device image model used for the makeup check also compares the face crop with
the descriptions "a person with dark skin" and "a person with light skin" and
gives one number per face. This is an attribute inferred from faces, and it is
always on in the default looks (there is no separate switch; choosing the
original, or the "no retouch" level, does not use it for tone). It is used only
to decide, for that photo, how much of a look's brightening to take back so that
dark skin keeps its natural depth. It is kept in memory with that photo's other
face data while the photo is open; it is not shown, not written to disk, not
logged, not sent anywhere, and never used to identify, group or label people. It
needs no extra model or download. No ethnicity or age/gender is inferred.

On the iPad (and in the standalone Mac app), face detection uses Apple's
on-device Vision framework. Neither app keeps `known_people.json`, `people.json`
or `person_*.jpg`; its settings (hide the launch notice, break reminder, turn
person recognition off, automatic updates) are kept in the app's preferences.

**Per-person settings (from version 0.3).** When you import photos, the app
computes a face feature vector (OpenCV SFace) on your device for each clearly
seen face, to recognise the same person across that batch of photos so you can
set each person separately. The vectors and the 96 px thumbnails shown in the
people bar exist only in memory: they are not written to disk, not uploaded, and
disappear when you close the batch or clear it. The people bar appears only when
a batch contains two or more people. You can switch this off with "turn off
person recognition" in the settings (it is on by default). Versions before 0.3
do not do this.

**Optional age/sex model (planned for version 0.3).** An age/sex estimate can be
added as an optional download. The Mac app asks the first time you use
per-person settings; on the iPad you can download it manually in the settings.
It runs on your device and uploads no photos, and per-person settings work
without it. The download is described under "Network use".

## Network use

- **Update check (on by default).** When it starts, and about once a day while
  it is open, LRCDF asks the project's release servers (Gitee and GitHub)
  whether a newer version exists, by downloading a small public file that lists
  the current version. When there is one, it tells you, downloads only the parts
  that changed, checks their signature and installs them when it is not working
  on your photos; the version you had is kept so you can go back.
- **What the update check sends.** Nothing about you, your photos or your
  catalog. Like any download, the request itself shows the server your IP
  address, the time and LRCDF's version and platform; those servers (Gitee,
  GitHub) handle that under their own privacy policies. LRCDF itself keeps no
  record of it and has no server of its own.
- **Tethered shooting on the iPad (off by default).** Only after you tap
  "Start receiving" on the tethered-shooting page, and only until you tap stop or
  the app leaves the foreground, the iPad app listens on TCP port 2121 on local
  networks only (Wi-Fi, the iPad's own hotspot, USB networking; never mobile data)
  so a camera can upload photos by FTP. It makes no outgoing connection. The
  login defaults to the user name `lrcdf` and an 8-character random password
  created once on the device; you can change both in the app (letters, digits
  and - _ . @ only). The user name is kept in the app's settings and the password
  only in the iOS keychain (this device only). The password is shown on screen
  for you to type into the camera and is never logged or sent anywhere. Received photos go
  to the app's temporary folder and then into the normal import; videos and other
  files are deleted at once; nothing goes to your Photos library unless you tap
  save. This uses plain FTP, so while it is on the photos travel unencrypted on
  that local network, and anyone on it who knows the password (a weak one you set yourself makes this easier) could send photos
  to the app (but not read anything from it). iPadOS may ask once for local-network
  permission. Closing the tethered-shooting page does not stop reception: while
  it is receiving, the app always shows a "tethered · n photos" badge in its top
  row, and tapping that badge takes you to the page with the stop button.
- **Tethered shooting by USB cable (iPad, and the Mac sandbox's USB permission).**
  When you connect a supported camera by USB cable and tap "Start receiving",
  iPadOS asks once whether LRCDF may access the camera (the external camera, not
  the iPad's own). LRCDF then only reads photos newly taken on that camera and
  saves them in its own folder. It does not change the camera's settings, release
  the shutter, or delete anything on the memory card. Nothing is sent anywhere.
- **Turning it off.** You can switch automatic updates off in LRCDF's settings at
  any time. With it off, LRCDF makes **no outgoing network connections** while running:
  no update check. (Tethered shooting, if you turn it on,
  only receives from your local network, as described above.)
- **Optional age/sex model (planned for version 0.3).** If you choose to
  download it, the app fetches one model file from the project's release page
  on GitHub. The request shows GitHub your IP address, the time and the app's
  version, handled under GitHub's privacy policy; nothing about you or your
  photos is sent. Nothing is downloaded unless you choose it.
- Installing LRCDF may download the software itself, its dependencies (for
  example Python packages) and its model files from the servers of the project's
  release page, your package manager or the model publishers. Those downloads are governed by the privacy policies of those
  services, not by LRCDF, and carry no photo data.

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
