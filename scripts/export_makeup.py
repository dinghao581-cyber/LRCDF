"""Development only: the make-up scorer as one self-contained file for the pipeline and the packaged app.
MobileCLIP2-S2 (Apple, open_clip 'dfndr2b') image encoder, reparameterised, with the zero-shot direction
("a face wearing make-up" minus "a face without make-up", x100) baked in, traced to TorchScript, weights in half
precision. -> ~/LRCDF/models/makeup/makeup_s2.pt. Input (1,3,256,256) RGB 0..1, output the scores (1,2):
[make-up, skin depth]. Skin depth ("dark skin" minus "light skin" prompts, x100; about -8 light .. +5 dark) is what
the tone step holds its brightening back by (lrcdf/skinkeep.py, docs/skin_mac/REPORT.md).
At run time neither open_clip nor a download is needed (beautify.makeup_of). Same prompts as the iPad app
(ipad/scripts/cm_makeup.py)."""
import os, torch, open_clip
from timm.utils.model import reparameterize_model
name = "MobileCLIP2-S2"
model, _, pre = open_clip.create_model_and_transforms(name, pretrained="dfndr2b"); model.eval()
tok = open_clip.get_tokenizer(name)
pos = ["a close-up photo of a face wearing makeup", "a face with eyeshadow, eyeliner and blush", "a woman wearing makeup and lipstick", "a made-up face"]
neg = ["a close-up photo of a face without makeup", "a bare face with no makeup", "a natural face, no cosmetics", "a face with bare skin"]
with torch.no_grad():
    t = model.encode_text(tok(pos + neg)); t = t / t.norm(dim=-1, keepdim=True)
    direction = (t[:4].mean(0) - t[4:].mean(0)) * 100
    dpos = ["a photo of a person with dark skin", "a close-up photo of a face with dark brown skin", "a portrait of a Black person", "a person with a deep, dark skin tone"]
    dneg = ["a photo of a person with light skin", "a close-up photo of a face with fair skin", "a portrait of a pale-skinned person", "a person with a light skin tone"]
    u = model.encode_text(tok(dpos + dneg)); u = u / u.norm(dim=-1, keepdim=True)
    depth_dir = (u[:4].mean(0) - u[4:].mean(0)) * 100
norm = [m for m in pre.transforms if m.__class__.__name__ == "Normalize"][0]
visual = reparameterize_model(model.visual)
class Score(torch.nn.Module):
    def __init__(s):
        super().__init__(); s.v = visual
        s.register_buffer("mean", torch.tensor(norm.mean).view(1, 3, 1, 1)); s.register_buffer("std", torch.tensor(norm.std).view(1, 3, 1, 1))
        s.register_buffer("d", torch.stack([direction, depth_dir], 1))
    def forward(s, x):
        f = s.v((x - s.mean) / s.std); f = f / f.norm(dim=-1, keepdim=True)
        return f @ s.d
net = Score().eval()
x = torch.rand(1, 3, 256, 256)
with torch.no_grad():
    ref = net(x)[0].tolist()
    tr = torch.jit.trace(net, x).half()
out = os.path.expanduser("~/LRCDF/models/makeup"); os.makedirs(out, exist_ok=True)
tr.save(f"{out}/makeup_s2.pt")
back = torch.jit.load(f"{out}/makeup_s2.pt").float()
with torch.no_grad(): print("check: original", ref, "saved file", back(x)[0].tolist())
