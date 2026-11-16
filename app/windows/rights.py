"""Rights.swift: the launch prompt, the rights card and the break reminder."""
from PySide6.QtCore import QRectF, QSettings, Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QApplication, QScrollArea, QWidget

from . import icons
from .i18n import tr
from .rights_text import DISCLAIMER, INVITE, LINKS, POINTS, QUESTION


class Rights:
    def __init__(self, window):
        self.window = window
        self.settings = QSettings("LRCDF", "LRCDF")
        self.active = self.away = 0
        self.timer = QTimer(window)
        self.timer.setInterval(30_000)
        self.timer.timeout.connect(self.tick)
        self.timer.start()
        self.banner = None

    def launch_prompt(self):
        if not self.settings.value("rights.hidePrompt", False, type=bool):
            self.open_prompt()

    def open_prompt(self):
        """RightsPrompt: 460 wide, 32 padding, corner 18; question 24 semibold, invite 16 soft, two capsules,
        the 'don't ask' checkbox (12, soft); 18 apart."""
        from .theme import SEMIBOLD, SOFT
        from .widgets import CapsuleButton, CheckBox
        from .window import C, HC, Panel, col, hrow, line, para

        panel = Panel(18, 460)
        v = col(18, (32, 32, 32, 32))
        q = para(QUESTION, 24, SEMIBOLD)
        q.setFixedWidth(396)
        v.addWidget(q, 0, HC)
        v.addWidget(line(INVITE, 16, color=SOFT, align=C))
        hide = CheckBox(tr("rights.hide"), size=12, color=SOFT)

        def dismiss():
            if hide.checked:
                self.settings.setValue("rights.hidePrompt", True)
            self.window.close_modal()

        v.addSpacing(4 - 18 + 18)
        v.addLayout(hrow(CapsuleButton(tr("rights.learn"), self.open_card, filled=True),
                         CapsuleButton(tr("rights.continue"), dismiss, filled=False), spacing=12))
        v.addWidget(hide, 0, HC)
        panel.setLayout(v)
        self.window.show_modal(panel, 0.62)

    def open_card(self):
        """RightsCard: 560 x 600, 26 padding, corner 18; title 20 semibold with a close cross; then a scrolling
        list 14 apart."""
        from .theme import LINE, LINK, MEDIUM, SEMIBOLD, SOFT, TEXT, css
        from .widgets import CheckBox, IconButton, ScrollStyle
        from .window import Panel, box, col, line, para, row

        panel = Panel(18, 560, 600)
        v = col(0, (26, 26, 26, 26))
        head = row()
        head.addWidget(line(tr("rights.title"), 20, SEMIBOLD), 1)
        head.addWidget(IconButton("xmark", self.window.close_modal, box=30, glyph=12, weight=0.11))
        v.addLayout(head)
        v.addSpacing(10)
        content = col(14, (0, 0, 8, 0))

        def text(t, size, weight=400, color=TEXT):
            w = para(t, size, weight, color, center=False)
            w.setFixedWidth(490)
            return w

        content.addWidget(text(DISCLAIMER, 12, color=SOFT))
        for title, body in POINTS:
            c = col(3)
            c.addWidget(text(title, 14, SEMIBOLD))
            c.addWidget(text(body, 13, color=SOFT))
            content.addWidget(box(c))
        content.addWidget(_Rule())
        content.addWidget(text(tr("rights.help"), 14, SEMIBOLD))
        for name, how, url in LINKS:
            c = col(2)
            from .widgets import label
            link = label(name, 13, MEDIUM, LINK)
            link.setFixedHeight(18)
            link.setTextFormat(Qt.TextFormat.RichText)
            link.setText(f'<a style="color:{css(LINK)};text-decoration:none" href="{url}">{name}</a>')
            link.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)
            link.linkActivated.connect(lambda address: QDesktopServices.openUrl(QUrl(address)))
            c.addWidget(link)
            c.addWidget(text(how, 12, color=SOFT))
            content.addWidget(box(c))
        content.addWidget(_Rule())
        prompt = CheckBox(tr("rights.remind"), not self.settings.value("rights.hidePrompt", False, type=bool))
        prompt.toggled.connect(lambda value: self.settings.setValue("rights.hidePrompt", not value))
        content.addWidget(prompt)
        rest = CheckBox(tr("rights.rest_remind"), self.settings.value("rights.breakReminder", True, type=bool))
        rest.toggled.connect(lambda value: self.settings.setValue("rights.breakReminder", value))
        content.addWidget(rest)
        content.addStretch(1)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet(ScrollStyle.SHEET)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setWidget(box(content))
        v.addWidget(scroll, 1)
        panel.setLayout(v)
        self.window.show_modal(panel, 0.62)

    def tick(self):
        if QApplication.activeWindow() is self.window:
            self.away = 0
            self.active += 30
        else:
            self.away += 30
            if self.away >= 600:
                self.active = 0
        if self.active >= 5400 and not self.banner and self.settings.value("rights.breakReminder", True, type=bool):
            self.show_banner()

    def show_banner(self):
        """BreakBanner: a capsule on the panel colour, 18 x 12 padding, at most 680 wide, 24 from the bottom;
        moves up and fades in."""
        from .theme import FOCUS, SOFT, TEXT
        from .widgets import PlainButton, fade, text_width
        from .window import line, row

        banner = _Banner()
        r = row(14, (18, 12, 18, 12))
        r.addWidget(_Cup())
        t = line(tr("rights.rest_message"), 14)
        r.addWidget(t, 1)
        r.addSpacing(12 - 14 + 14)
        r.addWidget(PlainButton(tr("rights.rest"), lambda: self.acknowledge(True), color=FOCUS))
        r.addWidget(PlainButton(tr("rights.rest_later"), lambda: self.acknowledge(False), color=SOFT))
        banner.setLayout(r)
        banner.setParent(self.window)
        w = min(680, self.window.width() - 48)
        banner.resize(w, 46)
        r.activate()
        h = 46
        if text_width(t.font(), t.text()) > t.width():
            # a longer translation wraps instead of being cut; the capsule grows to fit
            from .widgets import Para
            wrapped = Para(t.text(), 14, center=False)
            r.replaceWidget(t, wrapped)
            t.deleteLater()
            width = t.width()
            wrapped.setFixedWidth(width)
            h = max(46, len(wrapped._lines(width)) * wrapped.step + 24)
            banner.resize(w, h)
        x = (self.window.width() - w) // 2
        y = self.window.height() - h - 24
        banner.move(x, y + 20)
        fade(banner, 0, animate=False)
        banner.show()
        banner.raise_()
        fade(banner, 1, 200)
        from PySide6.QtCore import QPoint, QPropertyAnimation
        anim = QPropertyAnimation(banner, b"pos", banner)
        anim.setDuration(200)
        anim.setStartValue(QPoint(x, y + 20))
        anim.setEndValue(QPoint(x, y))
        anim.start()
        self.banner = banner

    def acknowledge(self, rest):
        from .widgets import fade
        self.active = 0 if rest else 3600
        banner, self.banner = self.banner, None
        if banner is not None:
            fade(banner, 0, 200)
            QTimer.singleShot(220, banner.deleteLater)


class _Rule(QWidget):
    def __init__(self):
        super().__init__()
        self.setFixedHeight(1)

    def paintEvent(self, _e):
        from .theme import LINE
        from .widgets import painter
        painter(self).fillRect(self.rect(), LINE)


class _Banner(QWidget):
    def paintEvent(self, _e):
        from .theme import LINE, PANEL, black, paint_shadow
        from .widgets import painter
        p = painter(self)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(LINE)
        p.setBrush(PANEL)
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)


class _Cup(QWidget):
    def __init__(self):
        super().__init__()
        self.setFixedSize(18, 18)

    def paintEvent(self, _e):
        from .theme import TEXT
        from .widgets import painter
        icons.cup(painter(self), QRectF(self.rect()), TEXT, 0.08)
