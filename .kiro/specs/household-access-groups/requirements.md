---
kind: change
status: active
created: 2026-11-04
issue: 1062
---
# Requirements: household-access-groups

## Introduction

`platform/keycloak/realm/access.conf` gates the user apps with two audience
groups: `family` (the household and the relatives together) reaches Immich,
Audiobookshelf, Calibre-Web, Mealie, Paperless and Home Assistant; `media`
(friends) reaches Immich and the two book apps. Paperless and Home Assistant
are therefore open to every relative.

This spec gives each audience its own group. `household` holds the household
members and is the only audience of Paperless and Home Assistant.
`relatives` and `friends` both reach Immich, Mealie, Audiobookshelf and
Calibre-Web; they are two groups because their Immich access will differ
later. `family` and `media` go away. People who lose an app lose it in the
app too, not only at the next Keycloak login. Opening an app to more people
later is one group on one line, never a grant to one person.

Non-goals:
- User accounts and group membership in git. They stay in the Keycloak admin
  console, so the public repo holds no names (access-identity, non-goals).
- Different Immich access for relatives and friends, and album sharing by
  group. Immich has no user groups yet; they are on its
  [roadmap](https://immich.app/roadmap) ("User groups"). Albums stay shared
  per user, and partner sharing stays one person to another. Deferred:
  #1073.
- Roles inside Paperless: one editor and one reader, as
  [paperless-documents](../paperless-documents/) Requirement 6 defines them.
- A single login for the theater admin UIs (#1063), Plex behind SSO for some
  users (#1064), Jellyfin SSO (#730), a request app for people outside the
  household (#731). Each one picks its gate from the groups defined here.
- Admin rights inside Immich and Mealie: set in each app by hand, unchanged.

## Glossary

- **Household members**: the operator and the other adult of the household.
- **Relatives**, **friends**: people outside the household with a Keycloak
  user.
- **Audience group**: a Keycloak group named for who its members are
  (`household`, `relatives`, `friends`), listed on the `access.conf` line
  of each app that audience may open.
- **Admin group**: `admins` and the per-app admin groups `ArgoCDAdmins`,
  `TheaterAdmins`, `HomeAssistantAdmins`, all with OTP (`platform.conf`
  `mfa_groups`). Unchanged by this spec.
- **Gate**: the `access-<client>` flow of a client: a user without the
  client role `access` gets Keycloak's "Access denied" page.
- **App account**: the account an app creates at a person's first Keycloak
  login, with its own session (Mealie and Paperless keep one for a year,
  [architecture.md](../../../docs/architecture.md#sessions)).

## Requirements

### Requirement 1: One group per audience

**User story:** As the operator, I want a group to say who its members are,
so that the gate of an app reads as the audiences it serves.

#### Acceptance criteria

1. THE realm `homelab` SHALL have the audience groups `household` (the
   household members), `relatives` and `friends`, besides the admin groups.
   AFTER the migration, the groups `family` and `media` SHALL NOT be listed
   in `access.conf` and SHALL NOT exist in the realm. (`access.conf`; admin
   console, Groups)
2. EVERY group listed in `access.conf` SHALL be described in the header of
   that file: who its members are, not their names.
3. `household`, `relatives` and `friends` SHALL NOT be in `mfa_groups`:
   their members log in with a password and set up OTP only if they want to
   (access-identity Requirement 7.2).

### Requirement 2: Each app opens to the decided audiences

**User story:** As a household member, I want Paperless and Home Assistant
to be ours; as a relative or a friend, I want to keep the photos, the
recipes and the books.

#### Acceptance criteria

1. THE app clients SHALL map the role `access` to exactly these groups:

   | Client | App | Groups |
   | --- | --- | --- |
   | `home-assistant` | Home Assistant (`home`) | `admins` `HomeAssistantAdmins` `household` |
   | `immich` | Immich (`media`) | `admins` `household` `relatives` `friends` |
   | `audiobookshelf` | Audiobookshelf (`audiobooks`) | `admins` `household` `relatives` `friends` |
   | `calibre-web` | Calibre-Web (`ebooks`) | `admins` `household` `relatives` `friends` |
   | `mealie` | Mealie (`cook`) | `admins` `household` `relatives` `friends` |
   | `paperless` | Paperless (`archive`) | `admins` `household` |

   The platform clients (`argocd`, `grafana-oauth`, `headlamp`, `hubble`,
   `signoz`, `syncthing`) and `theater-sso` (the *arr admin UIs: `admins`
   `TheaterAdmins`) are unchanged. (`keycloak-realm-settings` log: `ok
   client <client> access groups=<groups, sorted>` for each line)
2. WHEN a user in `relatives` or `friends` only opens Home Assistant or
   Paperless, THE gate SHALL show "Access denied"; Immich, Mealie,
   Audiobookshelf and Calibre-Web SHALL log them in. (access-identity
   Requirement 2.2)
3. THE operator SHALL keep every app through `admins` at every step of the
   migration, and the Keycloak admin console (`master` realm) SHALL be
   unaffected.

### Requirement 3: Paperless stays one editor and one reader

**User story:** As the editor, I want only the reader to see the household's
documents, whoever else joins `household` later.

#### Acceptance criteria

1. THE Paperless gate SHALL be `admins` and `household`, and THE member list
   in SOPS SHALL stay what decides who sees documents: a member of
   `household` who is not on it gets no Paperless group and sees no
   document. (paperless-documents Requirement 6.3)
2. Relatives SHALL lose Paperless at the gate.

### Requirement 4: The migration locks nobody out by accident

**User story:** As the operator, I want each step to be safe on its own, so a
half-done migration leaves everyone with what they had.

#### Acceptance criteria

1. THE groups `household`, `relatives` and `friends` SHALL be added to the
   app lines before any group is removed from them; that change alone SHALL
   take no access away from anyone.
2. `family` and `media` SHALL be removed from `access.conf` only after every
   household member is in `household`, every relative in `relatives`, every
   friend in `friends`, and both groups have no members (operator check in
   the admin console, recorded on #1062 as member counts, never names). No
   member of `family` SHALL be held there by git: the pentest test user
   moves to `household` before that check (design.md, Migration).
3. UNTIL the groups `family` and `media` are deleted, reverting the removal
   SHALL restore the previous mappings with no other step: the
   `keycloak-realm-settings` Job maps the reverted lines again.

### Requirement 5: Losing an app ends the app session

**User story:** As the operator, I want a relative who loses Home Assistant
or Paperless to be out of it now, not when their app session ends.

#### Acceptance criteria

1. FOR each relative with a Home Assistant or Paperless account, THE
   operator SHALL check the account, and what it owns, in that app's admin
   UI, from a checklist an agent prepares in chat. No agent holds app admin
   credentials for this. Names SHALL NOT go into git, a pull request or an
   issue.
2. IN Home Assistant, AN account that owns nothing SHALL be deleted as in
   [add-a-person.md, Remove a person](../../../docs/runbooks/add-a-person.md#remove-a-person),
   step 2; an account that owns devices or tokens SHALL be disabled ("Can
   log in" off).
3. Paperless SHALL have nothing to delete: an account outside the member
   list has no Paperless group and sees no document. Only its count SHALL be
   recorded.
4. Immich, Mealie, Audiobookshelf and Calibre-Web accounts SHALL NOT be
   deleted: relatives and friends keep those apps.
5. THE number of accounts deleted and disabled per app SHALL be recorded on
   #1062.

### Requirement 6: Mealie keeps the household's plans private

**User story:** As a household member, I want to share recipes with
relatives and friends but keep our meal plans and shopping lists to
ourselves.

#### Acceptance criteria

1. EVERY Mealie account of a relative or a friend SHALL be in a Mealie
   household other than the household's: Mealie shares recipes across its
   group and keeps meal plans and shopping lists per Mealie household. A
   Mealie admin sets it in Admin settings, Users, after the person's first
   login. (Mealie, Admin settings, Users: the household column)
2. THE runbook [add-a-person.md](../../../docs/runbooks/add-a-person.md)
   SHALL say so in its Mealie step.

### Requirement 7: Opening an app to more people goes through a group

**User story:** As the operator, I want to open an app to someone new later
without a one-off grant.

#### Acceptance criteria

1. THE runbook `add-a-person.md` SHALL say how to open an app to more
   people: add an audience group to the app's line in `access.conf` (an
   existing one, or a new one named for its members) and merge; the person
   joins that group. A grant to one person is not possible: the gate maps
   groups only.
2. THE runbook SHALL say that a Home Assistant administrator joins
   `HomeAssistantAdmins` before their first Home Assistant login, because
   `hass-oidc-auth` sets the admin role only when it creates the user.

### Requirement 8: The docs and specs name the new groups

**User story:** As someone reading the public repo, I want one description of
who reaches what.

#### Acceptance criteria

1. THE header of `access.conf`, the group table of
   [architecture.md](../../../docs/architecture.md#per-app-access), the
   runbook `add-a-person.md`, `docs/paperless.md`,
   `docs/home-automation.md` and the active specs that name the group
   (`paperless-documents`, `pentest-programme`) SHALL describe `household`,
   `relatives` and `friends` and SHALL NOT name `family` or `media` as a
   Keycloak group. The `pentest-programme` phrase "family phone" SHALL
   become "household phone". (`git grep -n -w family` over these files
   returns one line only: the "Area" tag row of
   `paperless-documents/design.md`, where `family` is a Paperless tag;
   `grep -n -w -E 'family|media' platform/keycloak/realm/access.conf`
   returns nothing)

## Decided

Rows marked "operator" are his decisions; the others are defaults with their
reason. Each one is a line in git or a console step, so changing it later is
one PR.

| Topic | Decision | Reason |
| --- | --- | --- |
| Paperless (operator, 2026-11-04) | The operator as editor, the other adult as reader, nobody else | Gate `household`; the SOPS member list stays the real control (Requirement 3) |
| Mealie, Audiobookshelf, Calibre-Web (operator, 2026-11-05) | `household`, `relatives` and `friends` | Relatives keep the recipes and the books; friends get the same access as relatives |
| Relatives and friends (operator, 2026-11-05) | Two groups with the same apps for now | Their Immich access will differ later (#1073); people sorted now do not move again |
| Home Assistant (operator, 2026-11-04) | `household` | Confirmed on 2026-11-04 |
| Home Assistant administrators (operator, 2026-11-05) | Only the operator (`HomeAssistantAdmins`); the other adult a normal user | Requirement 7.2 for a later administrator |
| *arr admin UIs (operator, 2026-11-04) | Admins only: `admins` and `TheaterAdmins`, unchanged | The single login is #1063 |
| Immich (operator, 2026-11-04) | The operator is the Immich admin; household members, relatives and friends through their own accounts and shared albums | Immich has no user groups (#1073) |
| Plex, Jellyfin (operator) | Off SSO | The TV apps; a partial SSO for Plex is research in #1064 |
| Group names | `relatives` and `friends` replace `family` and `media` | [design.md, Decisions](design.md#decisions) |
| The account of #1065 | `friends`, where #1065 moved it to `media` | It gets Immich, Mealie and the books like every friend; Immich-only would be one more audience group (Requirement 7.1), decided on #1065 |
| Who is in `household` | The operator and the other adult | #1062; the operator's `admins` membership already covers every app, `household` lists the household |
| OTP | Not for `household`, `relatives` or `friends` | access-identity Requirement 7.2 |
| App accounts of relatives in Home Assistant and Paperless | The operator checks them from an agent's checklist; Home Assistant: deleted when they own nothing, disabled otherwise; Paperless: count only | A Keycloak denial does not end an app session; no agent holds app admin credentials (Requirement 5) |
| Mealie accounts of relatives and friends | A Mealie household of their own | The household's meal plans and shopping lists stay private (Requirement 6) |
| Pentest test user | In `household` before step B, never `family` | A test user held in `family` by git would keep `family` from emptying (design, Migration) |
| Membership changes | The operator, in the admin console | Users stay out of git; the console is the only place they are |
