---
title: Privacy
summary: What this site records about its visitors, why, and for how long.
---

This site runs no script and loads nothing from another site. It keeps no
statistics. It sets one cookie, and only if you ask for it: when you pick
the light theme. The only other record of a visit is the access log below.

## Access logs

The web server writes one log line per request, with these fields:

| Field | Example |
| --- | --- |
| Time | `2026-11-13T14:00:00+00:00` |
| Method | `GET` |
| Path | `/privacy/` |
| Status | `200` |
| Bytes sent | `5120` |

It does not record your IP address, your browser's user agent, the page you
came from or the query string.

- Why: to find errors and broken links and to keep the server running.
- How long: 15 days, then the lines are deleted.

## Cookie

Pick the light theme (the sun at the top right) and the site remembers it
with one cookie:

| Field | Value |
| --- | --- |
| Name | `theme` |
| Value | `light`, nothing else |
| Set | When you click the sun, never otherwise |
| Sent to | `nedsi.io` and its subdomains: this blog, the homelab dashboard and the tech radar |
| Lasts | One year, or until you pick the dark theme, which deletes it |
| Used for | Sending you the light stylesheet |

It holds no identifier, no access log records it, and no script can read
it. It is a preference you asked for, and remembering it is all it does,
so there is no consent banner. To refuse it, don't click the sun. To
remove it, pick the dark theme or delete this site's cookies in your
browser.

## E-mail

If you write to me, your message and your address are kept in my mailbox at
Proton, in Switzerland, for as long as the conversation is useful, and are
never passed on. Ask and I delete them.

## Where the data is

The server is the author's own hardware in Switzerland. Its off-site
backups are stored with AWS in Frankfurt (`eu-central-1`). No data is
passed to anyone else.

## Legal basis

Legitimate interest in running a working and secure website: article
6(1)(f) of the GDPR, and the Swiss Federal Act on Data Protection (nFADP).

For the cookie: article 45c of the Swiss Telecommunications Act (you are
told about it here and can refuse it) and, for readers in the EU, the
exemption in article 5(3) of the ePrivacy Directive for what you explicitly
ask for.

## Contact and deletion

Write to [julien@nedsi.io](mailto:julien@nedsi.io) to ask what is held
about you or to have it deleted. The logs hold no address, so a line can
only be found by its time and path; every line is deleted after 15 days in
any case.
