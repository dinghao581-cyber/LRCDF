"""A window without the Windows title bar, like `.windowStyle(.hiddenTitleBar)` on the Mac: the dark content
reaches the top edge, the top 28 px drag the window, and Windows keeps its resizing edges, snapping, shadow and
rounded corners (the frame styles stay; WM_NCCALCSIZE gives the frame's area to the client)."""
import ctypes
from ctypes import wintypes

from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from pathlib import Path

from PySide6.QtGui import QColor, QIcon, QPen
from PySide6.QtWidgets import QApplication, QWidget

from . import icons
from .i18n import tr
from .theme import TEXT, white
from .widgets import Control, painter

TOP = 28                       # the Mac title bar's height that content stays clear of
EDGE = 6                       # resize border, logical px

WM_NCCALCSIZE, WM_NCHITTEST = 0x0083, 0x0084
HTCLIENT, HTCAPTION = 1, 2
HTLEFT, HTRIGHT, HTTOP, HTTOPLEFT, HTTOPRIGHT, HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT = 10, 11, 12, 13, 14, 15, 16, 17
GWL_STYLE = -16
WS_CAPTION, WS_THICKFRAME, WS_MINIMIZEBOX, WS_MAXIMIZEBOX, WS_SYSMENU = 0x00C00000, 0x00040000, 0x00020000, 0x00010000, 0x00080000
SWP_FLAGS = 0x0001 | 0x0002 | 0x0004 | 0x0020          # NOSIZE NOMOVE NOZORDER FRAMECHANGED

user32 = ctypes.windll.user32
dwm = ctypes.windll.dwmapi
user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
user32.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.SetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]


class NCCALCSIZE_PARAMS(ctypes.Structure):
    _fields_ = [("rgrc", wintypes.RECT * 3), ("lppos", ctypes.c_void_p)]


APP_ID = "LRCDF.Desktop"   # the taskbar groups our windows under this ID, not under python.exe


def identity():
    """LRCDF's own taskbar button and icon: an explicit AppUserModelID (set before the first window shows, or
    Windows files the window under pythonw.exe) and LRCDF.ico for every window, dialogs included."""
    try:
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(ctypes.c_wchar_p(APP_ID))
    except (AttributeError, OSError):
        pass
    icon = Path(__file__).with_name("LRCDF.ico")
    if icon.exists():
        QApplication.setWindowIcon(QIcon(str(icon)))


def dark_frame(window):
    """Dark title bar, system menus and borders, also when Windows itself is set to light."""
    on = ctypes.c_int(1)
    dwm.DwmSetWindowAttribute(int(window.winId()), 20, ctypes.byref(on), 4)


def prepare(window):
    """Call once after the window has a handle (after show)."""
    hwnd = int(window.winId())
    style = user32.GetWindowLongPtrW(hwnd, GWL_STYLE)
    user32.SetWindowLongPtrW(hwnd, GWL_STYLE, style | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU)
    dark_frame(window)
    round_ = ctypes.c_int(2)
    dwm.DwmSetWindowAttribute(hwnd, 33, ctypes.byref(round_), 4)             # Windows 11 rounded corners
    border = ctypes.c_uint(0x001C1818)                                        # COLORREF of the panel colour
    dwm.DwmSetWindowAttribute(hwnd, 34, ctypes.byref(border), 4)
    user32.SetWindowPos(hwnd, 0, 0, 0, 0, 0, SWP_FLAGS)
    window.resize(window.width(), window.height())


def handle(window, message, drag_test):
    """Answer the two frame messages; returns (handled, result)."""
    msg = wintypes.MSG.from_address(int(message))
    if msg.message == WM_NCCALCSIZE and msg.wParam:
        if user32.IsZoomed(msg.hWnd):
            # a maximised window reaches past the monitor by its frame: keep the client on the screen
            params = NCCALCSIZE_PARAMS.from_address(msg.lParam)
            dpi = user32.GetDpiForWindow(msg.hWnd)
            frame = user32.GetSystemMetricsForDpi(32, dpi) + user32.GetSystemMetricsForDpi(92, dpi)
            r = params.rgrc[0]
            r.left += frame
            r.top += frame
            r.right -= frame
            r.bottom -= frame
        return True, 0
    if msg.message == WM_NCHITTEST:
        x = ctypes.c_short(msg.lParam & 0xFFFF).value
        y = ctypes.c_short((msg.lParam >> 16) & 0xFFFF).value
        ratio = window.devicePixelRatioF()
        rect = wintypes.RECT()
        user32.GetWindowRect(msg.hWnd, ctypes.byref(rect))
        lx, ly = (x - rect.left) / ratio, (y - rect.top) / ratio
        w, h = (rect.right - rect.left) / ratio, (rect.bottom - rect.top) / ratio
        if not window.isMaximized():
            left, right = lx < EDGE, lx >= w - EDGE
            top, bottom = ly < EDGE, ly >= h - EDGE
            if top and left:
                return True, HTTOPLEFT
            if top and right:
                return True, HTTOPRIGHT
            if bottom and left:
                return True, HTBOTTOMLEFT
            if bottom and right:
                return True, HTBOTTOMRIGHT
            if left:
                return True, HTLEFT
            if right:
                return True, HTRIGHT
            if top:
                return True, HTTOP
            if bottom:
                return True, HTBOTTOM
        if ly < TOP and drag_test(QPointF(lx, ly)):
            return True, HTCAPTION
        return False, 0
    return False, 0


class CaptionButton(Control):
    """Minimise, maximise/restore, close and the rights help: plain glyphs on the window's dark top band,
    a faint white wash on hover (Windows red for close)."""

    def __init__(self, kind, action, width=46):
        super().__init__()
        self.kind = kind
        self.setFixedSize(width, TOP + 4)
        self.clicked.connect(action)
        self.setToolTip({"help": tr("rights.menu"), "min": tr("window.minimize"), "max": tr("window.maximize"),
                         "restore": tr("window.restore"), "close": tr("window.close")}.get(kind, ""))

    def set_kind(self, kind):
        self.kind = kind
        self.setToolTip({"max": tr("window.maximize"), "restore": tr("window.restore")}[kind])
        self.update()

    def paintEvent(self, _e):
        p = painter(self)
        r = QRectF(self.rect())
        if self.hovering or self.pressed:
            if self.kind == "close":
                p.fillRect(r, QColor(196, 43, 28) if not self.pressed else QColor(148, 32, 22))
            else:
                p.fillRect(r, white(0.06 if not self.pressed else 0.1))
        color = QColor(255, 255, 255) if self.kind == "close" and self.hovering else white(0.72)
        pen = QPen(color, 1.0)
        p.setPen(pen)
        p.setBrush(Qt.BrushStyle.NoBrush)
        c = r.center()
        if self.kind == "min":
            p.drawLine(QPointF(c.x() - 5, c.y() + 0.5), QPointF(c.x() + 5, c.y() + 0.5))
        elif self.kind == "max":
            p.drawRoundedRect(QRectF(c.x() - 5, c.y() - 5, 10, 10), 1.5, 1.5)
        elif self.kind == "restore":
            p.drawRoundedRect(QRectF(c.x() - 5, c.y() - 3, 8, 8), 1.5, 1.5)
            p.drawLine(QPointF(c.x() - 3, c.y() - 5), QPointF(c.x() + 4, c.y() - 5))
            p.drawLine(QPointF(c.x() + 5, c.y() - 4), QPointF(c.x() + 5, c.y() + 3))
        elif self.kind == "close":
            p.drawLine(QPointF(c.x() - 5, c.y() - 5), QPointF(c.x() + 5, c.y() + 5))
            p.drawLine(QPointF(c.x() - 5, c.y() + 5), QPointF(c.x() + 5, c.y() - 5))
        elif self.kind == "help":
            icons.question(p, QRectF(c.x() - 7, c.y() - 7, 14, 14), color, 0.075)
        elif self.kind == "gear":
            icons.gear(p, QRectF(c.x() - 7, c.y() - 7, 14, 14), color, 0.075)


class Caption(QWidget):
    """The buttons at the top right; everything else in the top band drags the window."""

    def __init__(self, window, on_help):
        super().__init__(window)
        self.window_ = window
        self.help = CaptionButton("help", on_help, 40)
        self.min = CaptionButton("min", window.showMinimized)
        self.max = CaptionButton("max", self._toggle)
        self.close_ = CaptionButton("close", window.close)
        self.buttons = [self.help, self.min, self.max, self.close_]
        self._place()

    def _place(self):
        x = 0
        for b in self.buttons:
            b.setParent(self)
            b.move(x, 0)
            b.show()
            x += b.width()
        self.setFixedSize(x, TOP + 4)

    def add_first(self, button):
        """Another button left of the others (the update settings)."""
        self.buttons.insert(0, button)
        self._place()
        self.sync()

    def _toggle(self):
        if self.window_.isMaximized():
            self.window_.showNormal()
        else:
            self.window_.showMaximized()

    def sync(self):
        self.max.set_kind("restore" if self.window_.isMaximized() else "max")
        self.move(self.window_.width() - self.width(), 0)
        self.raise_()
