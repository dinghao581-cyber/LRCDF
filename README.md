# Project website

A single static page for LRCDF and Tonewell. There is no build step, no framework and nothing loaded from another
server. `index.html` holds the markup, styles and script.

## Preview

Open `site/index.html` in a browser, or serve the folder, which is closer to how it runs once hosted:

```bash
python3 -m http.server 8000 --directory site
```

Then go to http://localhost:8000/.

## What to change at a release

All of these are in `index.html`.

| What | Where | Change |
|---|---|---|
| Download links | `<ul class="get">`, the `Get it` link in each row | LRCDF for Mac uses `/releases/latest` and needs no change. Windows, Tonewell for Mac and Tonewell for iPad link to a release tag: point them at the new tag. |
| Download sizes | `<ul class="get">`, the `first` line in each row | Use the size shown on the release page. |
| System requirements | `<ul class="get">`, the `needs` line in each row | Only if they changed. |
| Tonewell features | `<table class="compare">`, rows `row-people`, `row-learn`, `row-culling` | When a feature ships, change `<td class="no">No</td>` to `<td>Yes</td>`. If it reaches every platform, also revisit "This one is LRCDF only." under the group photo. |
| Interface languages | `row-language` | Both apps have 20 languages; change only if that stops being true. |
| Tethering | The `Tethered shooting` row | Add cameras only after they have been tested. |

## Rules for the content

- Describe only what the released apps do, and keep the limits next to the claims.
- No testimonials, download counts or competitor names.
- No analytics, cookies, web fonts from other hosts or scripts from a CDN. The footer says so.
- Before and after images must be real output with no manual edits.
- Every photo needs a credit in the footer. Use only adults, and prefer photos with a signed model release.

## Replacing a comparison image

1. Export the before and after with the same crop as WebP, named `img/<name>-before-<width>.webp` and
   `img/<name>-after-<width>.webp`, at the widths already used for that image.
2. Remove metadata from the files.
3. Replace the small blurred placeholder on the `<figure>`. It is the `background-image` in its `style`, a 24 px WebP
   of the before image. To print a new one (needs Pillow):

```bash
python3 -c "import base64,io,sys;from PIL import Image;i=Image.open(sys.argv[1]).convert('RGB');i.thumbnail((24,24));b=io.BytesIO();i.save(b,'WEBP',quality=40,method=6);print('data:image/webp;base64,'+base64.b64encode(b.getvalue()).decode())" site/img/NAME-before-WIDTH.webp
```

4. Update the `alt` text and the footer credit.

## Languages

The page itself is English. The switch in the header lists the 20 languages of the apps; the others are
`i18n/<code>.json`, fetched only when chosen (`?lang=<code>` opens one directly; the choice is remembered in the
browser). Every element that carries text has `data-i18n="<key>"` (or `data-i18n-alt` / `data-i18n-aria`), and
`i18n/en.json` lists the English text by key: it is the source for translators and is not loaded by the page.

When the English text changes, change it in `index.html` AND in `i18n/en.json`, then update the same key in every
other file. A key missing from a language shows the English text. Links inside a text (`<a href=…>`) must stay as
they are; only the words between the tags are translated.
