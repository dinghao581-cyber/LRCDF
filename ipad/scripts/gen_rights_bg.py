"""Background pictures for the rights prompt, made with OpenAI's image API (user 2026-11-15).

The key is read from the macOS keychain (item "openai", stored by the user with
`security add-generic-password -U -a "$USER" -s openai -w "$(pbpaste)"`); it is never printed or written anywhere.
Style: a public-information illustration about safe, fair work - no government crest, logo, flag or agency name, so
the app never looks like it speaks for the government.

usage: gen_rights_bg.py <out folder> [model] [first|posters|real]
"""
import base64, json, os, subprocess, sys, threading, urllib.request

out = sys.argv[1]; model = sys.argv[2] if len(sys.argv) > 2 else "gpt-image-2"
os.makedirs(out, exist_ok=True)
key = subprocess.run(["security", "find-generic-password", "-s", "openai", "-w"], capture_output=True, text=True).stdout.strip()

COMMON = (" Poster artwork for a public workplace-rights awareness campaign, in the spirit of Australian public-information "
          "posters: bold, confident, simple, warm. Leave a large calm empty area in the upper middle for a headline to be "
          "added later. Absolutely no text, letters, numbers, logos, crests, coats of arms, flags or emblems. Landscape.")
SETS = {
    "first": {
        "break": "A photo retoucher at a tidy desk by a large window turns away from the laptop to take a break, holding a cup of tea; eucalyptus trees and a soft evening sky outside; a clock on the wall. Modern flat illustration, soft gradients.",
        "together": "Three people of different backgrounds in a bright community workspace talk as equals over coffee. Modern flat illustration, soft gradients.",
        "outside": "A worker sits on a bench under a large gum tree beside a calm lake at golden hour. Modern flat illustration, soft gradients.",
    },
    "posters": {
        "p1_geometric": "Bold geometric mid-century modern poster: a large open raised hand made of simple flat shapes in front of a big ochre sun, eucalyptus-green and terracotta blocks, subtle paper grain.",
        "p2_linocut": "Two-colour linocut print poster: a photographer with a camera resting under a gum tree, strong carved lines, deep teal and warm ochre on cream paper.",
        "p3_riso": "Risograph poster in pink and teal with visible halftone and slight misregistration: a coffee cup, a wall clock and an empty chair by a window - the idea of taking a fair break.",
        "p4_collage": "Paper cut-out collage poster: many hands of different skin tones reaching in together towards the centre, torn-paper edges, warm earthy palette, soft shadows.",
        "p5_travel": "Vintage travel-poster style: a calm lake, low blue hills and gum trees at dawn, a small figure with a backpack walking home after work, long shadows, big sky.",
        "p6_shield": "Minimal modern poster: a simple umbrella sheltering a small figure from stylised falling geometric shapes, bold flat colours ochre, navy and eucalyptus green, lots of negative space.",
    },
    "real": {
        "r1_studio_break": "A real-life photograph: a young photo retoucher in a calm home studio leans back from the desk and stretches, a mug of tea beside the laptop, late-afternoon sun through a window with gum trees outside.",
        "r2_team": "A real-life photograph: a small creative team of different ages and backgrounds laughing together around a table in a bright studio, relaxed and respectful, cameras and prints on the table.",
        "r3_walk_home": "A real-life photograph: a photographer with a camera bag walking home along a lakeside path at golden hour, gum trees and low hills, seen from behind, peaceful.",
        "r4_hands": "A real-life photograph, close-up: several hands of different skin tones resting together on a wooden table next to cups of coffee, warm window light, shallow depth of field.",
        "r5_rest": "A real-life photograph: a worker in a hi-vis shirt sitting on a park bench under a big eucalyptus tree, eyes closed, enjoying a break, water bottle beside them, soft morning light.",
        "r6_talk": "A real-life photograph: two people talking calmly at a cafe table, one listening attentively with a notebook, supportive and safe atmosphere, warm natural light, blurred background.",
    },
}
which = sys.argv[3] if len(sys.argv) > 3 else "posters"
REAL = (" Editorial documentary photography for a public workplace-rights awareness poster: natural light, warm and hopeful, "
        "true-to-life colours, 35mm lens, shallow depth of field. Leave a large calm out-of-focus area in the upper middle "
        "for a headline to be added later. Absolutely no text, letters, numbers, logos, signs, crests, flags or emblems. Landscape.")
SCENES = {k: v + (REAL if which == "real" else COMMON) for k, v in SETS[which].items()}


def make(name, scene):
    body = json.dumps({"model": model, "prompt": scene, "size": "1536x1024", "n": 1}).encode()
    req = urllib.request.Request("https://api.openai.com/v1/images/generations", data=body,
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            d = json.load(r)
        open(f"{out}/{name}.png", "wb").write(base64.b64decode(d["data"][0]["b64_json"]))
        print("made", name, flush=True)
    except urllib.error.HTTPError as e:
        print("failed", name, e.code, json.loads(e.read() or b"{}").get("error", {}).get("message", ""), flush=True)


threads = [threading.Thread(target=make, args=kv) for kv in SCENES.items()]
for t in threads: t.start()
for t in threads: t.join()
