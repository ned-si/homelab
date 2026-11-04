# Tasks: household-access-groups

One pull request per task, in this order; tasks 2 and 4 are console and app
steps without a pull request, ticked with the date of their #1062 comment.
The steps A to D are in [design.md](design.md#migration). Requirement
numbers in brackets.

## Open

- [ ] 1. `feat(keycloak): household group on the household apps`: add
      `household` to the lines `home-assistant`, `immich`,
      `audiobookshelf`, `calibre-web`, `mealie` and `paperless` of
      `access.conf`, nothing removed; its header line. After the sync the
      Job log shows `creating group household` and the six `ok   client
      <client> access groups` lines with `household`. [1.2, 2.3, 4.1]
- [ ] 2. Operator, admin console: step B of design.md (household members
      into `household`, relatives from `family` to `media`, `family`
      empty); counts on #1062. [1.1, 4.2]
- [ ] 3. `feat(keycloak): household apps for the household only`: after
      the task 2 comment, remove `family` from every line and `media` from
      `audiobookshelf` and `calibre-web`; the header of `access.conf`;
      `docs/architecture.md` (per-app access table),
      `docs/runbooks/add-a-person.md` (groups table, join groups, opening an
      app to more people, the Mealie household, `HomeAssistantAdmins`
      before the first login), `docs/paperless.md`,
      `docs/home-automation.md`, and the group named in the
      `paperless-documents` and `pentest-programme` specs; the Job log and
      the `git grep` of design.md, Testing, in the pull request. [1.1, 2,
      3, 6, 7]
- [ ] 4. App accounts and the empty group: step D of design.md on a weekday
      during the day (local report with names, counts per app on #1062),
      then the operator deletes `family`. [1.1, 5]
- [ ] 5. Close: the access-identity area spec (a Done line, and Requirement
      2 if the per-app groups need naming there); `status: done`,
      `closed:`; #1062 closed.
