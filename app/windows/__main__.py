import sys

from PySide6.QtCore import QLockFile, QTimer
from PySide6.QtWidgets import QApplication

from .bridge import Bridge
from .studio import Studio
from .update_ui import WindowsUpdater
from .window import Window
from .workflow import Workflow


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("LRCDF")
    app.setOrganizationName("LRCDF")
    bridge = Bridge()
    bridge.root.mkdir(parents=True, exist_ok=True)
    lock = QLockFile(str(bridge.root / "desktop.lock"))
    lock.setStaleLockTime(0)
    if not lock.tryLock(0):
        return 0
    studio = Studio(bridge)
    workflow = Workflow(studio, bridge)
    window = Window(studio, workflow)
    updater = WindowsUpdater(window, studio, workflow, bridge)
    window.show()
    QTimer.singleShot(0, updater.start)
    app.aboutToQuit.connect(updater.stop)
    QTimer.singleShot(0, studio.start)
    app.aboutToQuit.connect(lock.unlock)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
