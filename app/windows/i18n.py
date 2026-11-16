"""Windows desktop UI strings, selected from the Windows display languages."""
import json
import os
import re
from pathlib import Path

from PySide6.QtCore import QLocale


TABLES = json.loads(Path(__file__).with_name("strings.json").read_text(encoding="utf-8"))
SOURCE = TABLES["zh-CN"]


def language_for(preferences):
    for preference in preferences:
        parts = preference.replace("_", "-").lower().split("-")
        base = parts[0]
        if base == "zh":
            if "hant" in parts or any(region in parts for region in ("tw", "hk", "mo")):
                return "zh-TW"
            return "zh-CN"
        if base == "pt":
            return "pt-BR"
        if base in {"no", "nb", "nn"}:
            return "nb"
        if base in TABLES:
            return base
    return "zh-CN"


def chinese_first(preferences):
    """Chinese anywhere in the Windows display languages wins over the ones before it (user, 2026-11-15: a Chinese
    speaker on an English Windows - en-AU, zh-CN - gets the Chinese interface); the order is otherwise kept."""
    preferences = list(preferences)
    chinese = [p for p in preferences if p.replace("_", "-").lower().split("-")[0] == "zh"]
    return chinese + [p for p in preferences if p not in chinese]


# LRCDF_LANG (e.g. "de") overrides the Windows display language, for testing and screenshots
LANGUAGE = language_for([os.environ["LRCDF_LANG"]] if os.environ.get("LRCDF_LANG")
                        else chinese_first(QLocale.system().uiLanguages()))
TEXTS = TABLES.get(LANGUAGE, SOURCE)
BRIDGE_KEYS = {
    text: key for key, text in SOURCE.items()
    if key.startswith(("bridge.progress.", "bridge.error.")) and "{" not in text
}


def tr(key, **values):
    text = TEXTS.get(key, SOURCE[key])
    return text.format(**values) if values else text


def bridge_text(text):
    if LANGUAGE == "zh-CN":
        return text
    key = BRIDGE_KEYS.get(text)
    if key:
        return tr(key)
    progress = re.fullmatch(r"正在降噪（(\d+)/(\d+)）…", text)
    if progress:
        return tr("bridge.progress.denoise", current=int(progress[1]), total=int(progress[2]))
    for error_key in ("bridge.error.model_failed", "bridge.error.retouch_failed", "bridge.error.model_missing"):
        prefix, suffix = SOURCE[error_key].split("{path}")
        if text.startswith(prefix) and text.endswith(suffix):
            path = text[len(prefix):len(text) - len(suffix)]
            return tr(error_key, path=path)
    return text


def look_text(look_id, title, note):
    if LANGUAGE == "zh-CN":
        return title, note
    title_key = f"look.{look_id}.title"
    note_key = f"look.{look_id}.note"
    if title_key in TEXTS and note_key in TEXTS:
        return tr(title_key), tr(note_key)
    if look_id.startswith("u"):
        if note == SOURCE["look.mine.title"]:
            return title, tr("look.mine.title")
        learned = re.fullmatch(r"我的风格 · 学自 (\d+) 张照片", note)
        if learned:
            return title, tr("look.mine.learned", count=int(learned[1]))
    return title, note
