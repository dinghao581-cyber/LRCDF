import math
import numpy as np
import torch
import torch.nn as nn
import torchvision
from lrcdf.image_io import imread
from . import params as P

SIZE = 224        # network input
CACHE = 288       # training cache resolution (random crops are taken from it)
N_STATS = 82
MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)


class ToneNet(nn.Module):
    """image + style id + as-shot white balance -> normalised develop-parameter vector."""

    def __init__(self, n_styles=3, pretrained=True):
        super().__init__()
        w = torchvision.models.ConvNeXt_Tiny_Weights.DEFAULT if pretrained else None
        net = torchvision.models.convnext_tiny(weights=w)
        self.backbone = net.features
        self.style = nn.Embedding(n_styles, 64)
        self.wb = nn.Linear(3, 32)
        self.stats = nn.Sequential(nn.BatchNorm1d(N_STATS), nn.Linear(N_STATS, 128), nn.GELU())
        self.head = nn.Sequential(nn.Dropout(0.2), nn.Linear(768 + 128 + 64 + 32, 512), nn.GELU(), nn.Dropout(0.5),
                                  nn.Linear(512, 512), nn.GELU(), nn.Dropout(0.5), nn.Linear(512, P.DIM))
        self.register_buffer("t_mean", torch.zeros(P.DIM))
        self.register_buffer("t_std", torch.ones(P.DIM))

    def features(self, img):
        x = (img - MEAN.to(img)) / STD.to(img)
        return torch.cat([self.backbone(x).mean((2, 3)), self.stats(colour_stats(img))], 1)

    def heads(self, feat, style, wb):
        return self.head(torch.cat([feat, self.style(style), self.wb(wb)], 1))

    def forward(self, img, style, wb):
        return self.heads(self.features(img), style, wb)


def colour_stats(x):
    """[B,3,H,W] sRGB 0..1 -> [B,82] global tone/colour statistics (exposure and WB live here, not in texture)."""
    with torch.no_grad():
        lin = x.clamp(1e-4, 1) ** 2.2
        lum = (lin * torch.tensor([0.2126, 0.7152, 0.0722], device=x.device).view(1, 3, 1, 1)).sum(1)
        q = torch.tensor([.01, .05, .25, .5, .75, .95, .99])
        c = x.shape[-1] // 4
        out = []
        for region in (slice(None), slice(c, -c)):
            l = lum[:, region, region].flatten(1)
            xr = x[:, :, region, region].flatten(2)
            m = lin[:, :, region, region].flatten(2).mean(2)
            out += [torch.log2(torch.quantile(l.cpu(), q, dim=1).T.to(x.device) + 1e-4), torch.log2(l.mean(1, keepdim=True) + 1e-4),
                    torch.log2(m[:, [0, 2]] / m[:, [1]]), (xr > 0.98).float().mean(2), (xr < 0.02).float().mean(2)]
        sat = (x.max(1).values - x.min(1).values).flatten(1)
        out.append(torch.stack([sat.mean(1), sat.std(1)], 1))
        bins = (x * 16).long().clamp(0, 15).flatten(2)
        out.append(torch.nn.functional.one_hot(bins, 16).float().mean(2).flatten(1))
        return torch.cat(out, 1)


def wb_feature(temp, tint, known):
    """as-shot WB as model input; zeros when unknown."""
    if not known:
        return [0.0, 0.0, 0.0]
    return [math.log(temp / P.T_DEFAULT), tint / P.TINT_SCALE, 1.0]


def load_image(path, size=SIZE):
    """Any image file -> float32 [3,size,size] in 0..1 (aspect squashed: only global look matters)."""
    import cv2
    im = imread(path, cv2.IMREAD_UNCHANGED)
    if im is None:
        import tifffile
        im = tifffile.imread(path)[..., ::-1]
    if im.ndim == 2:
        im = np.stack([im] * 3, -1)
    im = im[..., :3][..., ::-1]
    scale = 65535.0 if im.dtype == np.uint16 else 255.0
    im = cv2.resize(np.ascontiguousarray(im), (size, size), interpolation=cv2.INTER_AREA)
    return (im.astype(np.float32) / scale).transpose(2, 0, 1)
