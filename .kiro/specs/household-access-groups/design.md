# Design: household-access-groups

## Overview

Access stays where it is enforced today: one line per app client in
`platform/keycloak/realm/access.conf`, applied and read back by the PostSync
Job `keycloak-realm-settings` (`apply.sh` maps exactly the listed groups to
the client role `access`, creates a listed group that is missing, and
unmaps a group no longer listed). Group membership stays in the admin
console. The change is three lines of groups, done in an order that never
takes access away before the replacement is in place.

### Groups, before and after

| Group | Members | Before | After |
| --- | --- | --- | --- |
| `admins` | the operator | every app | unchanged |
| `household` (new) | household members | - | Home Assistant, Immich, Audiobookshelf, Calibre-Web, Mealie, Paperless |
| `family` | household members and relatives | Home Assistant, Immich, Audiobookshelf, Calibre-Web, Mealie, Paperless | deleted |
| `media` | friends; after: relatives and friends | Immich, Audiobookshelf, Calibre-Web | Immich |
| `ArgoCDAdmins`, `TheaterAdmins`, `HomeAssistantAdmins` | per-app admins, OTP | their app | unchanged |

### `access.conf` after the change

```text
argocd=admins ArgoCDAdmins
grafana-oauth=admins
theater-sso=admins TheaterAdmins
headlamp=admins
hubble=admins
signoz=admins
home-assistant=admins HomeAssistantAdmins household
immich=admins household media
audiobookshelf=admins household
calibre-web=admins household
mealie=admins household
paperless=admins household
```

Header lines for the audience groups:

```text
#   household  the household members: the household apps
#   media      relatives and friends: Immich
#   admins     the operator: every app
```

## Migration

| Step | Who | What | Access after the step |
| --- | --- | --- | --- |
| A | PR (task 1) | Add `household` to the six user-app lines; the Job creates the empty group | Unchanged for everyone |
| B | Operator, admin console (task 2) | Join the household members to `household`; move every relative from `family` to `media` (the account of #1065 included, if not done yet); check that `family` has no members | Household members: unchanged, through `household`. Relatives: Immich only, through `media`; the household apps deny them at the gate |
| C | PR (task 3) | Remove `family` from every line and `media` from the two book lines; docs and specs | Friends lose the books at the gate |
| D | Agent and operator (task 4) | App accounts of people who lost an app; then delete the empty `family` group | Nobody outside the household keeps a household-app session |

Relatives lose the household apps at the gate in step B, when they leave
`family`; step C then only removes empty or unused mappings, except for the
friends' books. Keeping both changes small makes each one easy to check and
to undo.

Rollback per step:

- A: revert the PR. `apply.sh` unmaps `household`; the empty group stays and
  is harmless.
- B: put the people back in `family` in the console.
- C: revert the PR while `family` still exists; the Job maps it again. Its
  members are gone after step B, so a revert of C alone restores the
  friends' books and nothing else; restoring the relatives' access is step B
  undone.
- D: a deleted app account is final, except an Immich user (not touched
  here). That is why step D deletes only accounts that own nothing and asks
  the operator about the others.

The operator keeps every app through `admins` at every step, and nothing
here touches the `master` realm, its OTP or the Job's client, so the admin
console and the realm Job keep working throughout.

### Step B checklist (operator, admin console, realm `homelab`)

1. Groups, `household`, Members, Add member: the household members.
   Expected: two members.
2. Groups, `family`, Members: for each relative, Users, the user, Groups,
   Join group `media`, then Leave group `family`.
   Expected: Groups, `family`, Members is empty.
3. Comment on #1062 with the counts only: `household: <n>`, `media: <n>`,
   `family: 0`.

### Step D: app accounts

An agent with each app's admin access, on a weekday during the day (the
risky-change window), lists per app the accounts of people outside
`household` and `admins`, with what each owns:

| App | Owns | Listed through |
| --- | --- | --- |
| Mealie | recipes created, meal plans, shopping lists | Admin settings, Users; the API `GET /api/admin/users` |
| Paperless | documents owned (the editor owns every document, so normally none) | the API `GET /api/users/` and the documents' owners |
| Audiobookshelf | progress, bookmarks | Settings, Users |
| Calibre-Web | shelves, reading state | Admin, Users |
| Home Assistant | devices, tokens | Settings, People, Users (advanced mode) |

The list, with usernames, goes into the local run report only. Accounts that
own nothing are deleted as in the runbook's "Remove a person", step 2.
Accounts that own something are listed for the operator in chat: keep them
disabled where the app offers it (Home Assistant "Can log in" off,
Audiobookshelf "Enable user" off) or delete them. The counts per app go on
#1062. The Paperless accounts left by the SSO tests are #1044's job and are
skipped here.

Then the operator deletes the group `family` (Groups, `family`, Delete).
Expected: Groups lists no `family`; the next `keycloak-realm-settings` run
logs no `creating group family`.

## Decisions

| Decision | Alternatives | Why |
| --- | --- | --- |
| Audience groups (`household`, `media`) on each app line | One user group per app (`mealie-users`, ...) | Two audiences, six user apps: a person joins one group and gets the right set; a per-app group multiplies console steps for each new person |
| Fold `family` into `media` | Keep `family` for relatives | After the change both groups reach Immich only; two groups with the same apps invite drift |
| Paperless gated by `household`, roles by the SOPS member list | A `paperless` group with two members | Two layers already: the gate keeps relatives and friends out, the member list decides editor and reader, and a later household member sees nothing until the editor lists them |
| `TheaterAdmins` kept on `theater-sso` | `admins` only | It is an admin group with OTP and the oauth2-proxy `allowedGroups` lists it; the single login is #1063 |
| Membership by the operator in the console | An agent through the Job's master client | Users stay out of git; an agent with `manage-users` could also reset passwords and OTP |
| No new check script | A Keycloak user-by-app matrix script | The Job's read-back already checks every mapping on each sync; the membership check is two console pages, done once |

### Opening an app to more people later

- Add an audience group to the app's line: `media` to give everyone with
  Immich the app, or a new group named for its members (for example
  `guests`) when the audience is different. `apply.sh` creates the group on
  the next sync; the operator adds the people.
- Mealie: Mealie shares recipes across its group and keeps meal plans and
  shopping lists per Mealie household. New Keycloak users land in the
  default household (no `DEFAULT_HOUSEHOLD`), which is the household's. A
  person from outside gets their own Mealie household, set by a Mealie admin
  after their first login.
- Home Assistant: `hass-oidc-auth` sets the admin role only when it creates
  the user, so a future administrator joins `HomeAssistantAdmins` before
  their first login.
- A request app (#731) gets its gate in its own spec, from these groups.

### Immich

The gate decides who may log in, not what each user sees. Inside Immich the
operator's account is the admin; everyone else has a normal account and sees
their own library, the albums shared with them and their partners'
libraries. Immich has no user groups yet ([roadmap](https://immich.app/roadmap),
"User groups"), so an album is shared with each user. #1073 waits for that
release.

## Error handling

| Failure | What happens |
| --- | --- |
| A household member is not in `household` when step C merges | Step C runs only after the `family: 0` comment of step B; if it happens anyway, the person sees "Access denied" in the household apps: join them to `household`, the next login works |
| A relative opens a household app after step B | "Access denied". It counts as a failed login: after 10 the account waits 60 s, then longer (`sessions.conf`), and the lock also blocks their Immich login. Tell relatives they keep Immich only; the operator clears a lock in Users, the user, Details |
| A relative still has an app session after step B | Step D ends it by deleting or disabling the app account |
| `apply.sh` fails or a mapping differs | The PostSync Job fails, the `keycloak` sync fails and the auto-rollback reverts the merge |
| Step C reverted after `family` was deleted | `apply.sh` recreates an empty `family`; nobody gets access back until the operator adds members |

## Testing

- Every PR: `tests/bash/test_keycloak_realm.sh` (the `access.conf` format)
  and the repo checks; nothing new to test there.
- After each merge: `kubectl -n keycloak logs job/keycloak-realm-settings`
  shows `ok   client <client> access groups <groups>` with the groups of the
  table in Requirement 2.1 for each line, and no `FAIL`.
- After step C: in the admin console, Clients, `mealie`, Client scopes,
  Evaluate, with a relative's user: the generated access token has no
  `mealie` role `access`; with a household member's user it has one. The pentest test user
  (pentest-programme) moves from `family` to `household` with task 3 and
  covers the household surface on each run.
- After task 3: `git grep -n -w family` over the files of Requirement 7.1
  finds no Keycloak group.

## Open questions

Operator preferences only; each has a default that applies if he does not
answer.

1. Friends in `media` lose Audiobookshelf and Calibre-Web. Default: yes, as
   the books follow Mealie. If a friend reads there, `media` stays on the two
   book lines.
2. Home Assistant administrators: only the operator (`HomeAssistantAdmins`),
   the other adult a normal user. Default: yes. If the other adult should
   edit dashboards and automations too, they join `HomeAssistantAdmins`
   (with OTP) before their first Home Assistant login.
