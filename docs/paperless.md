# Paperless

Paperless-ngx at `https://archive.lilalala.com`, namespace `paperless`. It
holds the household's documents. The way it is built is in the spec
[paperless-documents](../.kiro/specs/paperless-documents/design.md); this page says
how to operate it.

## Access

Logging in goes through Keycloak only. The Keycloak groups `admins` and
`family` may log in (`platform/keycloak/realm/access.conf`). Paperless
creates an account on the first login, with no group, so a new login sees
an empty dashboard and its profile, nothing else.

Inside Paperless there are two roles:

| Role | Paperless group | Can | Sees |
| --- | --- | --- | --- |
| Editor | `editors` | upload; view, change and delete documents, correspondents and notes; view types, tags, custom fields, saved views, file tasks and statistics | every document (the editor owns them all) |
| Reader | `readers` | view documents, correspondents, notes, types, tags, custom fields and saved views | every document without the `private` tag |
| Any other account | none | nothing | nothing |
| `nedsi-admin` | none, superuser | everything | everything: break-glass only |
| `automation` | none, superuser, API token only | everything | everything: the configuration Jobs |

Neither group has rights on users, groups, workflows, mail or settings. The
types, tags, custom fields, saved views and workflows are owned by git
(`apps/paperless/config/paperless.json`), so neither group may change them.

### Who is in which group

The member list is the SOPS Secret `apps/secrets/paperless-config.sops.yaml`,
key `config.json`, one JSON value:

```json
{"editors": ["<username or email>"], "readers": ["<username or email>"]}
```

An entry matches a Paperless account by username or by the email of the
Keycloak account, in any case. `apply.py` (the PostSync Job
`paperless-apply` and the nightly CronJob `paperless-apply-nightly` at
04:40 UTC) puts the listed accounts into their group and takes every other
account out of both groups. Its log has counts only:

```
group editors: 1 listed account(s) found
group readers: 1 listed account(s) found
accounts: 0 membership change(s); 0 account(s) other than nedsi-admin, automation, canary with the superuser flag or direct permissions
```

A listed person who has not logged in yet shows as `not found (no Paperless
login yet)`. Paperless refuses nothing because of it.

### Add a person

1. In the Keycloak admin console, realm `homelab`, put the user in the group
   `family`.
2. The person logs in once at `https://archive.lilalala.com`. They see an
   empty dashboard: that is expected.
3. Add their email (or Paperless username) to `editors` or `readers`:
   `sops edit apps/secrets/paperless-config.sops.yaml`, open a pull request,
   merge. The PostSync `paperless-apply` adds them.
4. If the entry was already listed before their first login, the next
   nightly run adds them. To do it at once:

   ```sh
   kubectl -n paperless create job --from=cronjob/paperless-apply-nightly paperless-apply-now
   kubectl -n paperless wait --for=condition=complete job/paperless-apply-now --timeout=15m
   kubectl -n paperless logs job/paperless-apply-now
   kubectl -n paperless delete job paperless-apply-now
   ```

   Expected in the log: `group readers: 1 listed account(s) found`.

To remove a person, delete their entry and merge; their account stays,
with no group, and sees nothing. Deleting the account itself is done in
Paperless (Settings, Users & Groups) as `nedsi-admin`; it cannot be undone.

### Sharing and hiding documents

- The workflow `share` gives `readers` view on every document uploaded
  through the web app or the API. The uploader stays the owner.
- The `private` tag is the only way to hide a document from the readers.
  The workflow `private` (the last one) removes their view and change
  rights when a document is added with the tag or edited while it has it.
- Removing the `private` tag makes the document readable again after the
  nightly run, or at once through the document's permissions dialog.
- Removing the readers' view in the permissions dialog without the tag
  lasts only until the nightly run, which gives it back.

### Dashboard

The saved views (Inbox, To pay, Tax year, Retention expired, Recently
added) belong to no account, so both groups see them under Documents,
Views. Which views sit on the dashboard is each person's own UI setting:
Settings, Saved views, "Show on dashboard". Only the person's own session
can write it.

### Break-glass

The editor's account is not a superuser. For administration, log in as
`nedsi-admin` with the password in `paperless-secrets`, key
`PAPERLESS_ADMIN_PASSWORD`, at
`https://archive.lilalala.com/accounts/login/?loggedout=1`. The
`loggedout=1` parameter stops the page's JavaScript redirect to Keycloak
(`PAPERLESS_REDIRECT_LOGIN_TO_SSO`), so the local form stays. The Django
admin is then at `/admin/`.

If that login fails, set the flag back from the pod, over the tailnet:

```sh
kubectl -n paperless exec deploy/paperless -- s6-setuidgid paperless python3 manage.py shell -c \
  "from django.contrib.auth.models import User; u = User.objects.get(username='nedsi-admin'); u.is_superuser = True; u.is_active = True; u.save(); print('ok')"
kubectl -n paperless exec -it deploy/paperless -- s6-setuidgid paperless python3 manage.py changepassword nedsi-admin
```

Expected: `ok`, then the password prompt. Seal the new password in
`paperless-secrets` afterwards ([secrets.md](secrets.md)).
