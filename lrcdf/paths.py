"""Where the things outside the project live: models and the legacy code. One place, so that an installation whose
files are not under the user's home (a Microsoft Store package: read-only, under WindowsApps) can say so.

home() is ~/LRCDF unless the environment variable LRCDF_HOME names another folder (the same name the Mac app's
updater tests use for their stand-in). The layout below it stays the same: models/, legacy/."""
import os


def home():
    return os.environ.get("LRCDF_HOME") or os.path.expanduser("~/LRCDF")


def models(*parts):
    return os.path.join(home(), "models", *parts)


def legacy(*parts):
    return os.path.join(home(), "legacy", *parts)
