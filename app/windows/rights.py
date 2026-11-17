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
        """RightsPrompt in a DialogPanel: 460 wide, 30 inside, corner 26, 18 apart: the question (display 26, centred),
        the invitation (16, soft), (4 more above) the main button and a quiet one side by side - stacked, 10 apart,
        when they do not fit - and the 'don't ask' checkbox (12 medium, soft) in a 44 row."""
        from .theme import BOLD, SOFT
        from .widgets import CheckBox, GhostButton, GlowButton
        from .window import C, HC, Panel, col, hrow, line, para

        panel = Panel(26, 460)
        v = col(18, (30, 30, 30, 30))
        q = para(QUESTION, 26, BOLD)
        from .theme import display
        q.f = display(26)                         # DS.display(26)
        q.setFixedWidth(400)
        v.addWidget(q, 0, HC)
        v.addWidget(line(INVITE, 16, color=SOFT, align=C))
        hide = CheckBox(tr("rights.hide"), size=12, color=SOFT)
        hide.setFixedHeight(44)
        hide.line_h = 44

        def dismiss():
            if hide.checked:
                self.settings.setValue("rights.hidePrompt", True)
            self.window.close_modal()

        v.addSpacing(4)
        first, second = GlowButton(tr("rights.learn"), self.open_card), GhostButton(tr("rights.continue"), dismiss)
        if first.width() + 12 + second.width() <= 400:          # ViewThatFits: side by side, else stacked
            v.addLayout(hrow(first, second, spacing=12))
        else:
            stack = col(10)
            stack.addWidget(first, 0, HC)
            stack.addWidget(second, 0, HC)
            v.addLayout(stack)
        v.addWidget(hide, 0, HC)
        panel.setLayout(v)
        self.window.show_modal(panel, 0.62)

    def open_card(self):
        """RightsCard in a DialogPanel: 560 wide, 30 inside, corner 26: the title (display 24) with the close cross
        (44 square, ink), 8 below it a 500 high scrolling list 14 apart (8 kept clear on the right)."""
        from .theme import BOLD, LINE, MEDIUM, SEMIBOLD, SOFT, TEXT, css
        from .widgets import CheckBox, IconButton, ScrollStyle
        from .window import Panel, box, col, line, para, row

        panel = Panel(26, 560)
        v = col(0, (30, 30, 30, 30))
        head = row()
        from .window import display_line
        head.addWidget(display_line(tr("rights.title"), 24), 1)
        head.addWidget(IconButton("xmark", self.window.close_modal, box=44, glyph=12, weight=0.11))
        v.addLayout(head)
        v.addSpacing(8)
        content = col(14, (0, 0, 8, 0))

        def text(t, size, weight=400, color=TEXT):
            w = para(t, size, weight, color, center=False)
            w.setFixedWidth(492)
            return w

        content.addWidget(text(DISCLAIMER, 12, MEDIUM, color=SOFT))
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
            link = label(name, 13, MEDIUM, TEXT)
            link.setFixedHeight(18)
            link.setTextFormat(Qt.TextFormat.RichText)
            link.setText(f'<a style="color:{css(TEXT)};text-decoration:underline" href="{url}">{name}</a>')
            link.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)
            link.linkActivated.connect(lambda address: QDesktopServices.openUrl(QUrl(address)))
            c.addWidget(link)
            c.addWidget(text(how, 12, MEDIUM, color=SOFT))
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
        scroll.setFixedHeight(500)
        v.addWidget(scroll)
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
        """BreakBanner: glass with corner 28, 22 x 6 inside, at most 760 wide, 24 from the bottom: the cup, the text
        (14), then "Take a break" (focus yellow) and "Later" (soft) as plain words in 44 rows; moves up and fades in."""
        from .theme import FOCUS, SOFT, TEXT
        from .widgets import PlainButton, fade, text_width
        from .window import line, row

        banner = _Banner()
        r = row(14, (22, 6, 22, 6))
        r.addWidget(_Cup())
        t = line(tr("rights.rest_message"), 14)
        r.addWidget(t, 1)
        r.addSpacing(12 - 14 + 14)
        rest = PlainButton(tr("rights.rest"), lambda: self.acknowledge(True), color=FOCUS)
        later = PlainButton(tr("rights.rest_later"), lambda: self.acknowledge(False), color=SOFT)
        for b in (rest, later):
            b.setFixedHeight(44)
            r.addWidget(b)
        banner.setLayout(r)
        banner.setParent(self.window)
        w = min(760, self.window.width() - 48)
        banner.resize(w, 56)
        r.activate()
        h = 56
        if text_width(t.font(), t.text()) > t.width():
            # a longer translation wraps instead of being cut; the capsule grows to fit
            from .widgets import Para
            wrapped = Para(t.text(), 14, center=False)
            r.replaceWidget(t, wrapped)
            t.deleteLater()
            width = t.width()
            wrapped.setFixedWidth(width)
            h = max(56, len(wrapped._lines(width)) * wrapped.step + 12)
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
        from .theme import PANEL, white
        from .widgets import painter
        p = painter(self)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(white(0.10))
        p.setBrush(PANEL)
        p.drawRoundedRect(r, 28, 28)


class _Cup(QWidget):
    def __init__(self):
        super().__init__()
        self.setFixedSize(18, 18)

    def paintEvent(self, _e):
        from .theme import TEXT
        from .widgets import painter
        icons.cup(painter(self), QRectF(self.rect()), TEXT, 0.08)
