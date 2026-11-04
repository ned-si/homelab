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
(friends) reaches Immich and the two book apps. The household-only apps are
therefore open to every relative.

This spec splits the household from everyone else. A new group `household`
holds the household members and is the gate of Mealie, the book apps,
Paperless and Home Assistant. Relatives join the friends in `media`, which
keeps Immich only, and `family` goes away. People who lose an app lose it in
the app too, not only at the next Keycloak login. Opening an app to more
people later is one group on one line, never a grant to one person.

Non-goals:
- User accounts and group membership in git. They stay in the Keycloak admin
  console, so the public repo holds no names (access-identity, non-goals).
- Album sharing by group in Immich. Immich has no user groups yet; they are
  on its [roadmap](https://immich.app/roadmap) ("User groups"). Albums stay
  shared per user, and partner sharing stays one person to another. Deferred:
  #1073.
- Roles inside Paperless: one editor and one reader, as
  [paperless-documents](../paperless-documents/) Requirement 6 defines them.
- A single login for the theater admin UIs (#1063), Plex behind SSO for some
  users (#1064), Jellyfin SSO (#730), a request app for people outside the
  household (#731). Each one picks its gate from the groups defined here.
- Opening Mealie or the book apps to anyone outside the household now.
- Admin rights inside Immich and Mealie: set in each app by hand, unchanged.

## Glossary

- **Household members**: the operator and the other adult of the household.
- **Relatives**, **friends**: people outside the household with a Keycloak
  user, for Immich today.
- **Audience group**: a Keycloak group named for who its members are
  (`household`, `media`), listed on the `access.conf` line of each app that
  audience may open.
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
   household members) and `media` (relatives and friends), besides the admin
   groups. AFTER the migration, the group `family` SHALL NOT be listed in
   `access.conf` and SHALL NOT exist in the realm. (`access.conf`; admin
   console, Groups)
2. EVERY group listed in `access.conf` SHALL be described in the header of
   that file: who its members are, not their names.
3. `household` and `media` SHALL NOT be in `mfa_groups`: their members log
   in with a password and set up OTP only if they want to (access-identity
   Requirement 7.2).

### Requirement 2: Each app opens to the decided audiences

**User story:** As a household member, I want the household apps to be ours;
as a relative or a friend, I want to keep the photos.

#### Acceptance criteria

1. THE app clients SHALL map the role `access` to exactly these groups:

   | Client | App | Groups |
   | --- | --- | --- |
   | `home-assistant` | Home Assistant (`home`) | `admins` `HomeAssistantAdmins` `household` |
   | `immich` | Immich (`media`) | `admins` `household` `media` |
   | `audiobookshelf` | Audiobookshelf (`audiobooks`) | `admins` `household` |
   | `calibre-web` | Calibre-Web (`ebooks`) | `admins` `household` |
   | `mealie` | Mealie (`cook`) | `admins` `household` |
   | `paperless` | Paperless (`archive`) | `admins` `household` |

   The platform clients (`argocd`, `grafana-oauth`, `headlamp`, `hubble`,
   `signoz`) and `theater-sso` (the *arr admin UIs: `admins`
   `TheaterAdmins`) are unchanged. (`keycloak-realm-settings` log: `ok
   client <client> access groups <groups>` for each line)
2. WHEN a user in `media` only opens Home Assistant, Audiobookshelf,
   Calibre-Web, Mealie or Paperless, THE gate SHALL show "Access denied";
   Immich SHALL log them in. (access-identity Requirement 2.2)
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

1. THE group `household` SHALL be added to the app lines before any group is
   removed from them; that change alone SHALL take no access away from
   anyone.
2. `family` SHALL be removed from `access.conf` only after every household
   member is in `household`, every relative in `media`, and the group
   `family` has no members (operator check in the admin console, recorded on
   #1062 as member counts, never names).
3. UNTIL the group `family` is deleted, reverting the removal SHALL restore
   the previous access with no other step: the `keycloak-realm-settings` Job
   maps the reverted lines again.

### Requirement 5: Losing an app ends the app session

**User story:** As the operator, I want someone who loses an app to be out of
it now, not when their year-long app session ends.

#### Acceptance criteria

1. FOR each app a person loses through this spec, THE person's app account
   SHALL be listed, with what it owns (recipes, documents, shelves, reading
   progress, devices), in a local report only, never in git, a pull request
   or an issue.
2. AN app account that owns nothing SHALL be deleted as in
   [add-a-person.md, Remove a person](../../../docs/runbooks/add-a-person.md#remove-a-person),
   step 2. AN account that owns something SHALL be listed for the operator,
   who decides to keep it disabled where the app allows it, or to delete it.
3. Immich accounts SHALL NOT be touched: relatives and friends keep Immich.
4. THE number of accounts deleted and kept per app SHALL be recorded on
   #1062.

### Requirement 6: Opening an app to more people goes through a group

**User story:** As the operator, I want to open Mealie or the books to
someone outside the household later without a one-off grant.

#### Acceptance criteria

1. THE runbook [add-a-person.md](../../../docs/runbooks/add-a-person.md)
   SHALL say how to open an app to more people: add an audience group to the
   app's line in `access.conf` (an existing one, or a new one named for its
   members) and merge; the person joins that group. A grant to one person is
   not possible: the gate maps groups only.
2. THE runbook SHALL say that people outside the household who open Mealie
   get their own Mealie household, so the household's meal plans and
   shopping lists stay private while the recipes are shared.
3. THE runbook SHALL say that a Home Assistant administrator joins
   `HomeAssistantAdmins` before their first Home Assistant login, because
   `hass-oidc-auth` sets the admin role only when it creates the user.

### Requirement 7: The docs and specs name the new groups

**User story:** As someone reading the public repo, I want one description of
who reaches what.

#### Acceptance criteria

1. THE header of `access.conf`, the group table of
   [architecture.md](../../../docs/architecture.md#per-app-access), the
   runbook `add-a-person.md`, `docs/paperless.md`,
   `docs/home-automation.md` and the active specs that name the group
   (`paperless-documents`, `pentest-programme`) SHALL describe `household`
   and `media` and SHALL NOT name `family` as a Keycloak group. (`git grep
   -n -w family` over these files finds no group reference)

## Decided

Rows marked "operator" are his decisions; the others are defaults with their
reason. Each one is a line in git or a console step, so changing it later is
one PR.

| Topic | Decision | Reason |
| --- | --- | --- |
| Paperless (operator, 2026-11-04) | The operator as editor, the other adult as reader, nobody else | Gate `household`; the SOPS member list stays the real control (Requirement 3) |
| Mealie, Audiobookshelf, Calibre-Web (operator, 2026-11-04) | `household`; open to more people later through a group | Requirements 2 and 6 |
| Home Assistant (operator, 2026-11-04) | `household` | Confirmed on 2026-11-04 |
| *arr admin UIs (operator, 2026-11-04) | Admins only: `admins` and `TheaterAdmins`, unchanged | The single login is #1063 |
| Immich (operator, 2026-11-04) | The operator is the Immich admin; household members, relatives and friends through their own accounts and shared albums | Immich has no user groups (#1073) |
| Plex, Jellyfin (operator) | Off SSO | The TV apps; a partial SSO for Plex is research in #1064 |
| `family` | Folded into `media`, then deleted | After this spec both would reach Immich only; #1065 already moves one account from `family` to `media` |
| Friends on the books | `media` loses Audiobookshelf and Calibre-Web | The operator put the books with Mealie ("same as cook"); question 1 in [design](design.md#open-questions) |
| Who is in `household` | The operator and the other adult | #1062; the operator's `admins` membership already covers every app, `household` lists the household |
| Group names | Audience groups in lower case (`household`, `media`, a later one named for its members); per-app admin groups keep their names | Matches the groups in place; renaming `TheaterAdmins` and the others would touch three apps for no gain |
| OTP | Not for `household` or `media` | access-identity Requirement 7.2 |
| App accounts of people who lose an app | Deleted when they own nothing; listed for the operator when they do | A Keycloak denial does not end an app session (Requirement 5) |
| Membership changes | The operator, in the admin console | Users stay out of git; the console is the only place they are |
