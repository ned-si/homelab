# Design: household-access-groups

## Overview

Access stays where it is enforced today: one line per app client in
`platform/keycloak/realm/access.conf`, applied and read back by the PostSync
Job `keycloak-realm-settings` (`apply.sh` maps exactly the listed groups to
the client role `access`, creates a listed group that is missing, and
unmaps a group no longer listed). Group membership stays in the admin
console. The change is six lines of groups, done in an order that never
takes access away before the replacement is in place.

### Groups, before and after

| Group | Members | Before | After |
| --- | --- | --- | --- |
| `admins` | the operator | every app | unchanged |
| `household` (new) | household members | - | Home Assistant, Immich, Audiobookshelf, Calibre-Web, Mealie, Paperless |
| `relatives` (new) | relatives | - | Immich, Audiobookshelf, Calibre-Web, Mealie |
| `friends` (new) | friends | - | Immich, Audiobookshelf, Calibre-Web, Mealie |
| `family` | household members and relatives | Home Assistant, Immich, Audiobookshelf, Calibre-Web, Mealie, Paperless | deleted |
| `media` | friends | Immich, Audiobookshelf, Calibre-Web | deleted |
| `ArgoCDAdmins`, `TheaterAdmins`, `HomeAssistantAdmins` | per-app admins, OTP | their app | unchanged |

What changes for people: relatives lose Home Assistant and Paperless;
friends gain Mealie; household members keep everything.

### `access.conf` after the change

```text
argocd=admins ArgoCDAdmins
grafana-oauth=admins
theater-sso=admins TheaterAdmins
headlamp=admins
hubble=admins
signoz=admins
syncthing=admins
home-assistant=admins HomeAssistantAdmins household
immich=admins household relatives friends
audiobookshelf=admins household relatives friends
calibre-web=admins household relatives friends
mealie=admins household relatives friends
paperless=admins household
```

Header lines for every group of the file (task 1 adds the three new lines,
task 3 writes the full block):

```text
#   household            the household members: the household apps
#   relatives            relatives: photos, recipes and books
#   friends              friends: photos, recipes and books
#   admins               the operator: every app
#   ArgoCDAdmins         Argo CD administrators (OTP)
#   TheaterAdmins        the theater admin UIs (OTP)
#   HomeAssistantAdmins  Home Assistant administrators (OTP)
```

## Migration

| Step | Who | What | Access after the step |
| --- | --- | --- | --- |
| A | PR (task 1) | Add `household` to the six user-app lines and `relatives` and `friends` to the `immich`, `audiobookshelf`, `calibre-web` and `mealie` lines; the Job creates the three empty groups | Unchanged for everyone |
| B | Operator, admin console (task 2) | Household members into `household`, relatives into `relatives`, friends into `friends` (the account of #1065 included), each out of `family` and `media`; check that both are empty | Household members: unchanged. Relatives: Immich, Mealie and the books; Home Assistant and Paperless deny them at the gate. Friends: Immich and the books as before, and Mealie |
| C | PR (task 3) | Remove `family` and `media` from every line; docs and specs | Unchanged: both groups are empty |
| D | Operator, from an agent's checklist (task 4) | Home Assistant and Paperless accounts of relatives; Mealie households of relatives and friends; then delete the empty `family` and `media` groups | No relative keeps a Home Assistant session; the household's meal plans stay private |

Every access change happens in step B, one person at a time, in the
console. The two pull requests only add and remove group mappings that
nobody uses at that moment, so each one is easy to check and to undo.

The pentest test user (pentest-programme) moves to `household` before step
B, so nothing in git holds a member in `family`:

- pentest-programme task 1 has merged and the user is defined in git: task
  1 of this spec changes its group there from `family` to `household` in the
  same pull request.
- It is a console user: step B moves it like a household member.
- pentest-programme task 1 has not merged: it uses `household` from the
  start, which exists once task 1 of this spec has merged.

Rollback per step:

- A: revert the PR. `apply.sh` unmaps the three groups; the empty groups
  stay and are harmless.
- B: put the people back in `family` and `media` in the console.
- C: revert the PR while `family` and `media` still exist; the Job maps
  them again. They are empty after step B, so restoring the previous access
  is step B undone.
- D: a deleted Home Assistant account is final, which is why step D
  deletes only accounts that own nothing and disables the others. A Mealie
  household change is undone in the same page.

The operator keeps every app through `admins` at every step, and nothing
here touches the `master` realm, its OTP or the Job's client, so the admin
console and the realm Job keep working throughout.

### Step B checklist (operator, admin console, realm `homelab`)

1. Groups, `household`, Members, Add member: the household members.
   Expected: the household members, and nobody else.
2. Groups, `family`, Members: for each member, Users, the user, Groups.
   A household member (already in `household` from item 1): Leave group
   `family`. A relative: Join group `relatives`, then Leave group `family`.
   Expected: Groups, `family`, Members is empty.
3. Groups, `media`, Members: for each member, Join group `friends`, then
   Leave group `media`. The account of #1065, wherever it is, goes to
   `friends`. Expected: Groups, `media`, Members is empty.
4. Comment on #1062 with the counts only: `household: <n>`,
   `relatives: <n>`, `friends: <n>`, `family: 0`, `media: 0`.

### Step D: app accounts

The operator does step D in each app's admin UI, on a weekday during the day
(the risky-change window). An agent prepares a checklist in chat: per app,
the page, what an account owns, and the action. The operator works through
it and replies with the counts only, and the agent records them on #1062.
No agent holds app admin credentials for this, and no name is written
anywhere.

| App | Whose accounts | Page | Action |
| --- | --- | --- | --- |
| Home Assistant | relatives | Settings, People, Users (advanced mode) | delete when it owns nothing; owns devices or tokens: "Can log in" off |
| Paperless | relatives | Settings, Users & Groups | none, count only: the editor owns every document |
| Mealie | relatives and friends | Admin settings, Users | move to a Mealie household other than the household's |

The agent confirms the labels against the running versions when it writes
the checklist.

Paperless has nothing to delete. Accounts of people outside the member list
have no Paperless group and see no document (`paperless-apply` takes them
out of both groups every night), and the gate stops new logins. The
Paperless accounts left by the SSO tests are #1044's job and are skipped
here.

Then the operator deletes the groups `family` and `media` (Groups, the
group, Delete). Expected: Groups lists neither; the next
`keycloak-realm-settings` run logs no `creating group`.

## Decisions

| Decision | Alternatives | Why |
| --- | --- | --- |
| Audience groups on each app line | One user group per app (`mealie-users`, ...) | Three audiences, six user apps: a person joins one group and gets the right set; a per-app group multiplies console steps for each new person |
| New groups `relatives` and `friends`; `family` and `media` deleted | Keep `family` for the relatives and `media` for the friends | `family` reads as "the household and its relatives", the ambiguity that opened Paperless and Home Assistant to relatives; `media` is named for an app, not for its members, against the naming rule of Requirement 1. The cost is one console move per relative and friend, once, in step B |
| `relatives` and `friends` separate while their apps are the same | One group `guests` for both | The operator expects different Immich access for them (#1073); sorting people once now avoids a second move |
| Paperless gated by `household`, roles by the SOPS member list | A `paperless` group with two members | Two layers already: the gate keeps relatives and friends out, the member list decides editor and reader, and a later household member sees nothing until the editor lists them |
| `TheaterAdmins` kept on `theater-sso` | `admins` only | It is an admin group with OTP and the oauth2-proxy `allowedGroups` lists it; the single login is #1063 |
| Membership by the operator in the console | An agent through the Job's master client | Users stay out of git; an agent with `manage-users` could also reset passwords and OTP |
| No new check script | A Keycloak user-by-app matrix script | The Job's read-back already checks every mapping on each sync; the membership check is three console pages, done once |

### Opening an app to more people later

- Add an audience group to the app's line, or a new group named for its
  members (for example `neighbours`) when the audience is different.
  `apply.sh` creates the group on the next sync; the operator adds the
  people.
- Mealie: new Keycloak users land in the default Mealie household (no
  `DEFAULT_HOUSEHOLD`), which is the household's. A Mealie admin moves a
  relative or a friend to another Mealie household after their first login
  (Requirement 6).
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
release; the split between `relatives` and `friends` is ready for it.

## Error handling

| Failure | What happens |
| --- | --- |
| Someone is still in `family` or `media` when step C merges | Step C runs only after the `family: 0`, `media: 0` comment of step B; if it happens anyway, the person sees "Access denied": join them to their group, the next login works |
| A relative opens Home Assistant or Paperless after step B | "Access denied". It counts as a failed login: after 10 the account waits 60 s, then longer (`sessions.conf`), and the lock also blocks their other logins. Tell relatives they keep the photos, the recipes and the books; the operator clears a lock in Users, the user, Details |
| A relative still has a Home Assistant session after step B | Step D ends it by deleting or disabling the account |
| A relative or a friend sees the household's meal plans | Their Mealie account is still in the household's Mealie household: step D, Mealie row |
| `apply.sh` fails or a mapping differs | The PostSync Job fails, the `keycloak` sync fails and the auto-rollback reverts the merge |
| Step C reverted after `family` and `media` were deleted | `apply.sh` recreates them empty; nobody gets access back until the operator adds members |

## Testing

- Every PR: `tests/bash/test_keycloak_realm.sh` (the `access.conf` format)
  and the repo checks; nothing new to test there.
- After each merge: `kubectl -n keycloak logs job/keycloak-realm-settings`
  shows `ok   client <client> access groups=<groups, sorted>` with the
  groups of the table in Requirement 2.1 for each line, and no `FAIL`.
- After step C: in the admin console, Clients, `paperless`, Client scopes,
  Evaluate, with a relative's user: the generated access token has no
  `paperless` role `access`; with a household member's user it has one.
  The pentest test user (pentest-programme) moves to `household` before
  step B (Migration) and covers the household surface on each run.
- After task 3: `git grep -n -w family` over the files of Requirement 8.1
  returns exactly one line, the "Area" tag row of
  `paperless-documents/design.md` (`family` is a Paperless tag there), and
  `grep -n -w -E 'family|media' platform/keycloak/realm/access.conf`
  returns nothing. Task 3 replaces "family phone" with "household phone" in
  `pentest-programme`.

## To settle at implementation

Facts the reviews could not check without the running apps; the task named
settles each one before it starts.

1. Task 4: the "Can log in" label in Home Assistant against the running
   version.
2. Task 3: Clients, `paperless`, Client scopes, Evaluate shows the client
   role `access` only when the `roles` scope is a default scope of
   `paperless`; if it is not, the check reads the token of a real login
   instead.
3. Task 3: a Mealie admin can move an existing user to another Mealie
   household after their first login (Requirement 6 and the runbook text
   depend on it).
4. Task 1: whether pentest-programme task 1 has merged with its test user
   defined in git, which decides the Migration case for that user.
