"""Text transcribed from the Mac app Rights.swift."""

from .i18n import tr

QUESTION = tr("rights.question")
INVITE = tr("rights.invite")
DISCLAIMER = tr("rights.scope")

POINTS = [
    (tr("rights.pay.title"), tr("rights.pay.body")),
    (tr("rights.hours.title"), tr("rights.hours.body")),
    (tr("rights.contracting.title"), tr("rights.contracting.body")),
    (tr("rights.credit.title"), tr("rights.credit.body")),
    (tr("rights.safety.title"), tr("rights.safety.body")),
    (tr("rights.retaliation.title"), tr("rights.retaliation.body")),
    (tr("rights.forced.title"), tr("rights.forced.body")),
    (tr("rights.visa.title"), tr("rights.visa.body")),
]

LINKS = [
    (tr("rights.fwo.name"), tr("rights.fwo.body"), 'https://www.fairwork.gov.au'),
    (tr("rights.fwc.name"), tr("rights.fwc.body"), 'https://www.fwc.gov.au'),
    ('WorkSafe ACT', tr("rights.worksafe.body"), 'https://www.worksafe.act.gov.au'),
    (tr("rights.legal.name"), tr("rights.legal.body"), 'https://legalaidact.org.au'),
    (tr("rights.hrc.name"), tr("rights.hrc.body"), 'https://hrc.act.gov.au'),
    (tr("rights.afp.name"), tr("rights.afp.body"), 'https://www.afp.gov.au'),
    (tr("rights.tis.name"), tr("rights.tis.body"), 'https://www.tisnational.gov.au'),
    ('Lifeline', tr("rights.lifeline.body"), 'https://www.lifeline.org.au'),
]
