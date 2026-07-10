---
name: jmix-role-based-access
description: Overview of Jmix role-based access — resource vs row-level roles, security scope (UI/API), and the mandatory ui.loginToUi login invariant. Read this before creating any role.
---

# Role-based access in Jmix

Read this BEFORE adding or changing security, then use the specific skill:

- WHAT a user can do (entities, attributes, views, menu) → `jmix-create-resource-role`
- WHICH rows a user can access — read and create/update/delete per row → `jmix-create-row-level-role`

## Model

Two role kinds with OPPOSITE effects — do not conflate them:

- **Resource roles** (`@ResourceRole`) are ADDITIVE / no-deny: they GRANT access
  (entities, attributes, views, menu). If any assigned resource role grants
  something, the user has it, and there is no deny-policy. Compose them by
  `extend`ing several resource-role interfaces.
- **Row-level roles** (`@RowLevelRole`) are RESTRICTIVE: they narrow access at the
  ROW level — not only which rows a user can READ/see, but also which rows they can
  CREATE/UPDATE/DELETE (an effective row-level deny). With no row-level role a user
  has every row that resource roles permit; a row-level policy narrows that set.

The "additive / no-deny" property applies to resource roles only — it is NOT a
statement about the whole security model. A single role interface CANNOT mix
`@ResourceRole` and `@RowLevelRole`.

## Logging into the UI — a MANDATORY invariant (the most commonly missed defect)

Entity/view/menu grants do NOT let a user log into the UI. Any user who logs into
the web UI needs, in addition to domain roles, the `ui.loginToUi` specific
permission and access to `MainView`. Without it the login is
rejected with a generic "Login failed" AFTER authentication succeeds — a symptom
that looks like a wrong password but is actually a missing UI-access grant.

Pick one:
- assign the built-in **`ui-minimal`** resource role (code `"ui-minimal"`) to the
  user ALONGSIDE the domain role — preferred; or
- declare on the domain role itself
  `@SpecificPolicy(resources = "ui.loginToUi")` plus a `@ViewPolicy` covering
  `MainView`.

The default Full-Stack scaffold hides this: the demo `admin` is assigned
`system-full-access` (the full superuser role, which already includes UI login),
so the trap appears the moment you create YOUR OWN users with narrower roles. If
you seed users via Liquibase, assign `ui-minimal` in the same changeset next to
the domain role. Recognizable symptom: `admin` logs in but a domain-only
`manager`/`officer` gets "Login failed" with correct credentials.

**Self-check:** verify a seeded NON-admin user actually reaches `MainView`, not
"Login failed" — testing/verifying as `admin` (full access) masks this entirely.

## Security scope (UI vs API)

A role has a scope — `@ResourceRole(..., scope = SecurityScope.UI)`,
`SecurityScope.API`, or both — controlling where it applies (web UI vs REST/API
clients). Use `SecurityScope.UI` for roles that gate the web interface;
`ui-minimal` is UI-scoped. Scope does NOT replace the UI-login invariant above: a
UI-scoped domain role still cannot log in without `ui.loginToUi`.

## Diagnosing access problems (DEBUG logging)

Access denials are SILENT in the UI — a "Login failed" message, a hidden button,
or an empty grid, with no cause shown. Turn on DEBUG logging to see the actual
denial in the console instead of guessing:

```properties
logging.level.io.jmix.core.AccessLogger=DEBUG        # entity/attribute/row denials
logging.level.io.jmix.security=DEBUG
logging.level.org.springframework.security=DEBUG     # authentication / login rejection
```

The log then names the exact permission or row that was denied — turning a silent
"Login failed" or missing action into a concrete, fixable cause. Prefer this over
re-reading role code when a permission problem is suspected.

## Assigning roles to users

Roles take effect only when assigned to a user (role assignment). When seeding
users via Liquibase, insert both the domain role AND `ui-minimal` for each UI user
in the same changeset. A user with domain roles but no `ui-minimal`/`ui.loginToUi`
cannot log in.
