# Tasks: household-access-groups

One pull request per task, in this order. Tasks 2 and 4 are console and app
steps without a pull request of their own: task 2 is ticked in task 3's pull
request and task 4 in task 5's, each with the link to its #1062 comment.
The steps A to D are in [design.md](design.md#migration). Requirement
numbers in brackets.

## Open

- [ ] 1. `feat(keycloak): household group on the household apps`: add
      `household` to the lines `home-assistant`, `immich`,
      `audiobookshelf`, `calibre-web`, `mealie` and `paperless` of
      `access.conf`, nothing removed; its header line; if the pentest test
      user is defined in git, its group from `family` to `household`
      (design.md, Migration). After the sync the Job log shows `creating
      group household` and the six `ok   client <client> access
      groups=<groups, sorted>` lines with `household`. Settle item 5 of
      design.md, To settle at implementation. [1.2, 2.3, 4.1, 4.2]
- [ ] 2. Operator, admin console: step B of design.md (household members
      into `household` and out of `family`, every other member of `family`
      to `media`, `family` empty); counts on #1062. [1.1, 4.2]
- [ ] 3. `feat(keycloak): household apps for the household only`: after
      the task 2 comment, remove `family` from every line and `media` from
      `audiobookshelf` and `calibre-web`; the full group block in the header
      of `access.conf`; `docs/architecture.md` (per-app access table),
      `docs/runbooks/add-a-person.md` (groups table, join groups, opening an
      app to more people, the Mealie household, `HomeAssistantAdmins`
      before the first login), `docs/paperless.md`,
      `docs/home-automation.md`, the group named in the
      `paperless-documents` and `pentest-programme` specs, and "family
      phone" to "household phone" in `pentest-programme`; the Job log and
      the `git grep` of design.md, Testing, in the pull request; tick task
      2. Settle items 3 and 4 of design.md, To settle at implementation.
      [1.1, 1.2, 2, 3, 6, 7]
- [ ] 4. App accounts and the empty group: step D of design.md on a weekday
      during the day. The agent settles items 1 and 2 of design.md, To
      settle at implementation, and prepares the checklist in chat; the
      operator works through it in each app's admin UI and replies with
      counts (deleted, disabled, kept active), the agent posts the counts
      per app on #1062; then the operator deletes `family`. [1.1, 5]
- [ ] 5. Close: a Done line in the access-identity area spec (its
      Requirement 2 names no group, so it is unchanged); tick task 4;
      `status: done`, `closed:`; #1062 closed.
