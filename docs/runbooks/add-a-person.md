# Add or remove a person

Give someone access to the household's services, or take it away. Most apps
log in through Keycloak (realm `homelab`) and create their own account on
the person's first login; access is decided by Keycloak groups. Plex and
Jellyfin are off SSO and keep their own accounts.

Preconditions:

- The Keycloak admin console,
  `https://keycloak-admin.tail32a1fc.ts.net/admin/master/console/` (tailnet, owner or admin device), as the master `admin`
  (password and OTP, [keycloak-otp.md](keycloak-otp.md)). Switch the realm
  selector to `homelab` for every step below.
- An admin account in each app you configure: the operator's account (group
  `admins`) or the app's local break-glass admin.
- For Plex: the server owner's plex.tv account. For Jellyfin: a Jellyfin
  administrator.
- For Paperless: a checkout of this repository with `sops` and the age key
  ([secrets.md](../secrets.md)).

## Who gets what

The groups come from `platform/keycloak/realm/access.conf`; a user in no
group can log in to no app ([architecture.md](../architecture.md#per-app-access)).

| Keycloak group | For | Apps |
| --- | --- | --- |
| `family` | the household and relatives | Immich, Audiobookshelf, Calibre-Web, Mealie, Paperless, Home Assistant |
| `media` | friends | Immich, Audiobookshelf, Calibre-Web |
| `admins` | the operator | every app, plus OTP at every password login |
| `HomeAssistantAdmins` | Home Assistant administrators | Home Assistant, as an administrator |
| `TheaterAdmins` | the *arr admin UIs | `https://theater.lilalala.com/arr/<app>` |
| `ArgoCDAdmins` | Argo CD | `https://argo.lilalala.com` |
| none | Plex and Jellyfin only | their own accounts, see [Plex](#9-plex) and [Jellyfin](#10-jellyfin) |

Opening an app outside your groups shows Keycloak's "Access denied" page
and counts as a failed login for brute-force detection: after 10 failures
the account waits 60 s, then longer (`sessions.conf`). Tell the person which
apps they have.

## Add a person

### 1. Create the Keycloak user

1. Users, Add user:
   - Username: lower case, no spaces, stable. Calibre-Web names its account
     after it and Audiobookshelf matches existing accounts by it.
   - Email: required. Immich, Mealie and Paperless key their accounts on it.
   - First name, Last name: what the apps display.
   - Email verified: On. The admin sets every address; Mealie is configured
     for that (`OIDC_REQUIRES_EMAIL_VERIFICATION=false`).
   - Required user actions: leave empty.
   - Join groups: `family` or `media`, as in the table above.
   - Create.
2. Credentials, Set password: a temporary password, Temporary On. Keycloak
   adds the required action Update Password, so the person picks their own at
   the first login. Give them the temporary password in person or through the
   password manager, never by plain email.
3. OTP: only members of `admins` need it. They get the realm role
   `mfa-required` and Keycloak asks them to set up an authenticator after the
   password (required action `CONFIGURE_TOTP`, `platform.conf`
   `mfa_groups=admins`). Do not add Configure OTP for anyone else; they can
   turn it on themselves in the account console (Account security, Signing
   in). Enrolment and a lost phone: [keycloak-otp.md](keycloak-otp.md).

Expected: Users, the user, Groups lists the groups you picked; Details shows
Enabled On and Email verified On.

Check with the person: they open
`https://auth.lilalala.com/realms/homelab/account/`, log in with the
temporary password and set a new one. Expected: the account console with
their name.

### 2. First login in each app

The person logs in once to each app they will use, in a browser or the
mobile app. That login creates their account; the per-app settings below
need it to exist.

| App | Address | Mobile app |
| --- | --- | --- |
| Immich | `https://media.lilalala.com` | Immich: server `https://media.lilalala.com`, the OAuth login button |
| Mealie | `https://cook.lilalala.com` | the web app |
| Paperless | `https://archive.lilalala.com` | the web app |
| Audiobookshelf | `https://audiobooks.lilalala.com`, "Login with Keycloak" | Audiobookshelf: server `https://audiobooks.lilalala.com`, the OpenID login button |
| Calibre-Web | `https://ebooks.lilalala.com`, the OAuth login button | any OPDS reader, or Kobo and KOReader sync |
| Home Assistant | `https://home.lilalala.com` | Home Assistant Companion: server `https://home.lilalala.com` |

Immich, Mealie, Paperless and Home Assistant send the browser straight to
Keycloak. If Keycloak shows "Access denied", the user is not in a group that
the app's line in `access.conf` lists: fix the groups (step 1).

### 3. Immich

Configured in the SOPS Secret `immich-config`
(`apps/secrets/immich-config.sops.yaml.example` shows the structure): OAuth
with `autoLaunch` and `autoRegister` on. The first login creates a normal
(non-admin) user with the Keycloak email and name. If an Immich account with
that email already exists and is not linked to another login, the first
login is attached to it. Administration, Settings is read-only because the
config comes from the file; per-user settings are not.

1. Storage quota: Administration, Users, the user, Edit user, Quota size in
   GiB. Empty means unlimited, the default for new accounts here: the config
   sets no `defaultStorageQuota` and the realm sends no `immich_quota` claim.
   Every library shares the `immich-data` volume (2 TiB), so a quota keeps
   one phone's backup from filling it. Leave Storage label empty: applying a
   label moves files on the library volume.

   Expected: Administration, Users shows the quota next to the user.
2. Partner sharing (one person's whole library visible to another): each
   person, in their own account, Account settings, Partner sharing, Add
   partner, picks the other user. It works in one direction; for both, each
   adds the other. The partner then sees them under Sharing and can turn on
   "Show in timeline".
3. Shared albums: the album's owner opens it, Share, and picks users. Each
   invited user is an Editor (can add photos) or a Viewer. For someone
   without an account, Share, Create link instead, with an expiry and
   optionally a password; the link opens without a login.

### 4. Paperless

Paperless creates the account on the first login with no group, so the
person sees an empty dashboard until they are in the member list. Follow
[paperless.md, Add a person](../paperless.md#add-a-person): their email goes
into `readers` (or `editors`) in `apps/secrets/paperless-config.sops.yaml`
through a pull request.

Expected: after the merge, the `paperless-apply` log says
`group readers: <n> listed account(s) found` and the person sees the shared
documents.

### 5. Mealie

`apps/mealie/deployment.yaml`: OIDC on, `OIDC_AUTO_REDIRECT=true`,
`ALLOW_SIGNUP=false`. `ALLOW_SIGNUP` closes only the local registration form;
the first Keycloak login creates the user, in Mealie's default group and
household (`DEFAULT_GROUP` and `DEFAULT_HOUSEHOLD` are not set), where the
recipes are shared. No `OIDC_ADMIN_GROUP` is set, so admin rights are given
in Mealie by an admin.

Expected: Admin settings, Users lists the person.

### 6. Audiobookshelf

OpenID settings live in the app's database ([books.md](../books.md#login)):
auto register on, existing accounts matched by username, the local login
kept for the `root` break-glass account. The first login creates an account
with the `user` role.

As an admin: Settings, Users, the user. Check the libraries they may open
(Audiobooks, Podcasts) and the download permission.

Expected: the person sees the libraries in the app.

### 7. Calibre-Web

Login type "Use OAuth", generic provider, settings in its database
([books.md](../books.md#login)). The first login creates an account named
after the Keycloak username (an existing account is matched by name, then by
email). The default role for new users is empty, so the new account can
browse the catalogue but not read or download.

As an admin: Admin, Users, the user. Tick "Allow eBook Viewer" and "Allow
Downloads" (and "Allow Editing Public Shelves" if they share shelves), Save.

Expected: the person can open a book in the browser.

### 8. Home Assistant

`apps/home/config/configuration.yaml`, `auth_oidc` (hass-oidc-auth): the
login page redirects to Keycloak, and the first login creates a normal user.
Members of the Keycloak group `HomeAssistantAdmins` become administrators;
add the person to that group in step 1 only if they should change the setup.

Expected: Settings, People, Users (advanced mode on) lists the user.

### 9. Plex

Plex is off SSO: its TV apps cannot do a Keycloak login. People use their
own plex.tv account (or a managed user), and the server owner grants access
at `https://app.plex.tv`. The server publishes itself at
`https://theater.lilalala.com` (Settings, Network, Custom server access URLs).

Pick one:

- A friend or relative with their own Plex account: Settings, Manage Library
  Access, Grant Library Access, their email or Plex username, the server,
  the libraries, and restrictions if any. They accept the invitation at
  plex.tv.
- A child: Settings, Plex Home, add a managed user: a name, a restriction
  profile (Younger Kid, Older Kid or Teen), the libraries, and optionally a
  PIN. A managed user has no email and no password; the home's apps switch
  to it with Switch User. Inviting an existing regular account into the Plex
  Home needs Plex Pass, and so do custom restrictions
  ([Plex Home](https://support.plex.tv/articles/204234313-example-plex-home-setup/)).

Remote playback: since 2025-04-29, playing personal videos away from the
server's network needs a Plex Pass on the server owner's account or a Remote
Watch Pass on the viewer's
([Plex](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/)).
On the home network it stays free.

TV apps: install Plex, choose Sign in, and enter the code shown at
`https://plex.tv/link` while logged in as the person (for a managed user, as
the home's owner, then Switch User on the TV).

The Plex watchlist import in Sonarr and Radarr reads only the server owner's
watchlist ([theater.md](../theater.md#plex-watchlist)); a friend's watchlist
starts no download.

Expected: the person's apps list the server and the shared libraries.

### 10. Jellyfin

Jellyfin at `https://cinema.lilalala.com` keeps local accounts: SSO for it
waits on #730.

1. As a Jellyfin administrator: Dashboard, Users, Add user. A name and a
   password; "Enable access to all libraries" or pick the libraries;
   Create.
2. For a child: the user's Parental control tab, Maximum allowed parental
   rating, Save.
3. Leave "Allow this user to manage the server" off.

Apps: server address `https://cinema.lilalala.com`. On a TV, choose Quick
Connect (on, [architecture.md](../architecture.md#sessions)): the TV shows a
code, and the person enters it on their phone, logged in to Jellyfin, under
Settings, Quick Connect.

Expected: the person logs in and sees the libraries you picked.

## Remove a person

Keycloak access and app sessions are separate. Taking the groups away stops
every new SSO login at once, but app sessions last long (Immich tokens do
not expire, Mealie and Paperless keep a session for a year,
[architecture.md](../architecture.md#sessions)), so each app account is
removed in the app too.

1. Keycloak: Users, the user, Groups: leave every group. Sessions: Sign out.
   Details: Enabled Off, Save.

   Expected: a login to any app shows "Access denied" or "Account is
   disabled".
2. In each app the person used:

   | App | Where | What goes with it |
   | --- | --- | --- |
   | Immich | Administration, Users, the user's menu, Delete user | The account is disabled at once; its photos, videos and albums are deleted after 7 days (Immich's default delay). Copy anything others want to keep first: a shared album shows another person's photos but does not copy them |
   | Paperless | the member list, as in [paperless.md](../paperless.md#add-a-person) | The account keeps no group and sees nothing; documents stay, owned by the editor |
   | Mealie | Admin settings, Users, delete | Their account |
   | Audiobookshelf | Settings, Users, delete | Their progress and bookmarks |
   | Calibre-Web | Admin, Users, the user, Delete User | Their shelves and reading state; the library stays |
   | Home Assistant | Settings, People, Users (advanced mode on), the user, Delete; their phone under Settings, Devices & services, Mobile App | Their login tokens and the phone's device |
   | Plex | `https://app.plex.tv`, Settings, Manage Library Access (or Plex Home), the user, remove | Their access to the server; their plex.tv account stays theirs |
   | Jellyfin | Dashboard, Users, the user, Delete; check Dashboard, Devices | Their account and devices |

3. A tailnet device of theirs, if any: remove it
   ([remote-access.md](../remote-access.md#revoke-a-device)).
4. Delete the Keycloak user (Users, the user, Delete) only after step 2.
   Calibre-Web and Audiobookshelf match accounts by username, and Immich,
   Mealie and Paperless by email: a new Keycloak user with the same username
   or email would take over an app account that is still there.

## Rollback

- A person added by mistake: remove them as above.
- Groups taken away by mistake: join them again; new logins work at once.
- An Immich user deleted by mistake: Administration, Users, Restore, within
  the 7 days. Every other app deletion is final; restoring one means
  restoring that app's backup ([backups.md](../backups.md)).
