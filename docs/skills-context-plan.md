# Plan: make the Jmix skills cheaper to load in a small context window

Related issue: [#216](https://github.com/jmix-framework/jmix-agent-toolkit/issues/216).

## Current state (v3, measured by characters / 4)

- 25 skills, about 266 KB in total, about 66k tokens. Each skill is a single `SKILL.md` with no supporting files, so reading a skill always loads all of it.
- Loaded in every session: the 25 descriptions (about 5.4 KB, about 1.4k tokens) and the guidelines block.
- Loaded per task: the `jmix` router asks the agent to read the skill of every artifact before writing. For a "new entity" task this is router + entity + changelog + role + i18n = 63.5 KB, about 16k tokens, before any project file is read. With the verification skills and list and detail views it grows to about 32k tokens.
- Largest skills: `jmix-create-entity` (22 KB), `jmix-migrate-theme-to-aura` (20 KB), `jmix-create-test` (19 KB), `jmix-create-detail-view` (17 KB), `jmix-create-list-view` (15 KB), `jmix-create-liquibase-changelog` (15 KB), `jmix-style-ui` (15 KB).
- Largest single sections: Gate 3 in `jmix-verify-bootrun` (7.8 KB), IDE inspection in `jmix-ide-static-analysis` (6.8 KB), `EntityChangedEvent` in `jmix-add-entity-event-listener` (5.6 KB), UI integration tests in `jmix-create-test` (5.4 KB).

Re-measure after each step with:

```bash
wc -c skills/*/SKILL.md | sort -n
```

## Step 1. Router and guidelines block (#216) — done

Files: `skills/jmix/SKILL.md`, `content/guidelines-block.md`.

- Replace "for EACH artifact, READ the matching skill" with on-demand reading:
  - no working example of the artifact kind in the module: read the full skill;
  - a working example exists: follow it and check the change against the skill's **Forbidden** section only.
- Replace "the skill wins" with a rule that depends on the kind of question. Memory is never a source.
  - How the project does things (id type, packages, naming, architecture): the project's existing code wins; do not rewrite existing code to match the skill.
  - Whether an API exists in this Jmix version: the result of `jmix-verify-api-symbol` wins (docs server when connected, otherwise `javap` on the resolved jars). The docs are not ranked as a source of their own, because they may not be connected and an agent without them falls back to memory of older Jmix versions.
  - Known failures (Forbidden lists, code that compiles and passes tests but fails later): the skill wins over docs examples. A failure in existing code is not copied into new code and is reported.
  - Conflicts are reported. Sample code from a plan or brief is below all of these.
- Give the commands of Gate 1 and Gate 2 directly in the router, so the gate skills are read once per session, when a gate fails, or for Gate 3, not for every task.
- In the guidelines block, limit the requirement to Java, view descriptors, changelogs and build files, and exempt edits to documentation only or to the text of existing messages.

Done when: the router no longer requires reading every skill, the precedence rule matches the list above, and `python3 tests/check_skill_frontmatter.py`, `bash tests/test_install_sh.sh` and `pwsh tests/test_install_ps1.ps1` pass.

## Step 2. Keep each rule in one skill — done

Keep the full rule in its owner skill and replace the copies with a one-line pointer:

| Rule | Owner | Copies to replace |
|---|---|---|
| Use of Context7 and `search-jmix-docs` | `jmix-verify-api-symbol` | `configure-fetch-plan`, `create-dto-entity`, `create-fragment`, `create-list-view`, `create-test` |
| 0-byte files after writes | `jmix` (Writing files) | `create-entity`, `ide-static-analysis` |
| CREATE implies MODIFY | `create-resource-role` | `ide-static-analysis` (keep the mechanical check line only) |
| Index parity | `create-entity` | `create-liquibase-changelog` |
| Required-field defaults not in `InitEntityEvent` | `create-entity` | `create-detail-view`, `ide-static-analysis` |
| "Authentication is not set" outside a user request | `run-background-code` | `create-service` |

Done when: `grep` for each rule finds the full text in the owner only.

## Step 3. Write rules more briefly and move special cases to the end — done

Result: all 23 skills (except the router) have the layout below; `jmix-migrate-theme-to-aura` keeps its step order. Each rewrite was compared with the old text by a separate agent, and every lost or weakened rule it found was restored. The content problems listed below are fixed. Sizes: the total grew from 263.5 KB to 275.1 KB, because every failure of the main part now also has a one-line Forbidden bullet and every special case has a pointer. The part an agent reads when no special case applies (everything before `## Special cases`) is 187.5 KB, 29% less than the old total. Step 5 can move the special cases out of `SKILL.md`.


Edit each skill once, doing all of the following in the same change.

### Shorter text

- One line per rule, with a short reason only when the rule is not obvious.
- Delete sections that repeat other sections, for example "Cost vs benefit" in `jmix-verify-api-symbol` and the parts of "Honest scope" in `jmix-verify-bootrun` that repeat Gate 3.
- Use fewer all-caps words.
- Remove the duplicate `exception.` line at the end of step 3 of the render walk in `jmix-verify-bootrun`.

### One layout for every skill

1. Steps.
2. The common patterns and templates.
3. `## Forbidden`. The router tells an agent that has a working example to check only this section, so it must hold every known failure of the common case.
4. `## Special cases`, always the last section. Each case is a `### When <condition>` subsection, where the condition is something the agent can see in the task or the code (for example "When the entity has a `@Composition` collection" or "When the parent is hard-deleted").

A step that leads into a special case names the subsection: "If the entity has a `@Composition` collection, read **When the entity has a `@Composition` collection** below." Special cases do not refer to each other.

This layout makes maintenance easier on its own: the common case is short and at the top, and each special case has one place. It also prepares step 5, where a `### When ...` subsection can become a reference file without rewriting it.

Proposed moves to `## Special cases`:

| Skill | Stays in the main part | Moves to `## Special cases` |
|---|---|---|
| `jmix-verify-bootrun` | Gate 2 | Gate 3 render walk; HSQLDB driver missing; stale classes in `.jmix/conf`; uploads in a non-root container |
| `jmix-create-entity` | steps, template, id strategy, required-field defaults | composition and cascade, delete policies, index parity, file attributes, embeddable and inheritance |
| `jmix-ide-static-analysis` | choice of path by connected tools, per-file loop | IDE inspection details, known false positives |
| `jmix-create-test` | unit, integration, security patterns | UI integration tests, fragments, dropdown items, hidden columns, code outside a user session |
| `jmix-create-detail-view` | the two render-time failures, steps, skeleton | reference fields, to-many grid, confirmation before save, cross-field validation |
| `jmix-create-list-view` | steps, skeleton | hierarchical list, URL query parameters, settings facet, saved user settings |
| `jmix-add-entity-event-listener` | steps, listener template | event timing, cascades, values derived from composition children |
| `jmix-configure-fetch-plan` | steps, XML and DataManager patterns | single-table inheritance, fetch modes, `BATCH` on nested collections |
| `jmix-style-ui` | active theme check, where styling belongs | token enumeration commands, no suitable token |
| `jmix-create-liquibase-changelog` | steps, standard types, skeleton | one-time data fixes, baselines, add-on changelogs, two referential actions |

The other skills get the same layout where they have special cases. `jmix-migrate-theme-to-aura` has `disable-model-invocation: true` and is a one-time procedure in steps, so it keeps its order and gets only the shorter text.

### Content problems to fix

Found while testing step 1:

- `jmix-verify-bootrun` calls Gate 3 "optional" in its description and under "When to use", but "REQUIRED for every view/role you created or changed" under the Gate 3 heading. The router now follows the second.
- `jmix-create-entity`, "Id strategy", describes UUID and assigned keys but not sequence-generated `Long` ids. It also does not say that a new entity follows the id strategy of the project's existing entities.
- `jmix-ide-static-analysis` says every `@NotNull` / `nullable=false` field needs an entity-layer default, while `jmix-create-entity` asks for one only when the field has a default value. Say what a required field entered by the user (for example `name`) needs.
- `jmix-create-entity` says "Spring Boot 3 uses `jakarta.*`"; the stack is Spring Boot 4.
- `jmix-create-entity`: the Forbidden bullet on required references covers `optional = false` without `@JoinColumn(nullable = false)`, while "Required references" asks for both annotations and does not mention `@NotNull`. Say whether `@NotNull` alone has the same failure and whether the field also needs `@NotNull`.
- `jmix-verify-api-symbol`, "A close-but-not-exact doc example still confirms the symbol", can be read as permission to follow a docs example that differs in JPA annotations. Say that it confirms only that the symbol exists, not that the example's annotations are complete.
- `jmix-verify-api-symbol` puts the docs server first but does not say that the resolved jars win when the two disagree (the docs server is filtered to `v3`, not to the pinned version). The router now says so; repeat it in the skill.
- `jmix-create-liquibase-changelog` has no guidance on creating a sequence for sequence-generated ids.
- `jmix-create-list-view` says a click handler with the wrong event type fails `compileJava`; `jmix-add-dialog-detail-flow` says it compiles and throws `IllegalArgumentException: argument type mismatch` at the click. Check which is true and keep the full rule in `jmix-add-dialog-detail-flow` only.

Done when: every skill in the table has the layout above, each rule is written once, and the frontmatter lint passes.

## Step 4. Shorten the descriptions — done

Result: the seven descriptions are 157–197 characters each. The total description size went from 5.2 KB to 3.8 KB, about 360 tokens less in every session.

A description says when to use the skill, not what the skill says. Shorten the long ones to about 200 characters: `jmix-verify-api-symbol`, `jmix-ide-static-analysis`, `jmix-run-background-code`, `jmix-style-ui`, `jmix-migrate-theme-to-aura`, `jmix-verify-bootrun`, `jmix-configure-observability`. Expected saving: about 600 tokens in every session.

Done when: the total description size is under 4 KB.

## Step 5. Split large skills into a core file and `references/`

Move `### When ...` subsections from `## Special cases` into `skills/<skill>/references/<topic>.md`. The pointer in the steps then names the file instead of the subsection. No agent loads a reference by itself: the agent must see the pointer and open the file. Weaker models skip pointers more often, and users with small context windows often run such models. So a missed reference must do little harm.

What may move to a reference: a special case only, and only if its condition is visible in the task or the code, or a mechanical check in `jmix-ide-static-analysis` or Gate 2 catches the failure even when the reference was not read. Everything else stays in `SKILL.md`, including the whole `## Forbidden` section.

Before the first split:

- Check that every supported agent (Claude Code, Codex, OpenCode, Junie) can open a file next to `SKILL.md` from a relative path. Put a test reference into one skill, install it into each agent, and ask the agent to read it. If an agent resolves the path against the project root, use paths from the skill folder that the installer knows, or keep that content in `SKILL.md`.
- Confirm that Studio's `AiSkillsHasher` hashes files in subfolders the same way `gen_skills_manifest.py` does (it walks the whole skill folder). The installers already copy the whole folder (`cp -R`). Commit the regenerated `.studio/skills-manifest.json` (CI also regenerates it).

Then try one skill first: `jmix-verify-bootrun`, moving the Gate 3 render walk out. Run scenarios where the condition holds (a view was created) and where it does not, with a small model (for example Haiku) and, if possible, a non-Claude model through Codex or OpenCode. Count how often the reference is opened in each case. Split the other skills only if the reference is opened reliably when the condition holds.

If the trial fails, keep the skills as single files with the step 3 layout.

Done when: the trial result is recorded here, and each split skill's `SKILL.md` is at most 6 KB.

## Step 6 (optional). Merge small skills that overlap

- `jmix-create-enum` into `jmix-create-entity`, as a special case (or a reference file after step 5).
- `jmix-create-composition-detail-view` into `jmix-create-detail-view`, the same way.

This shortens the routing list and the descriptions. Projects that installed an earlier version keep the removed skill folders unless the installers learn to delete them, so decide this together with the installer behavior.

## Step 7. Measure and enforce

- Add a size check to `tests/check_skill_frontmatter.py`: warn when a `SKILL.md` is over 8 KB, or fail over a higher limit.
- Add a script that prints the size of the skills a typical task reads (new entity, new view, new service) so a change can show its effect.
- If possible, run the same tasks with and without the skills and publish correctness, tokens and wall time, as #216 suggests.

## Other version branches

`skills/` and `content/` differ per branch and are not synced. Steps 1 to 6 apply to v3 here (step 1 is done on `v3_refactor`); decide separately whether to repeat them on v2. A size check from step 7 is a test change, so it goes to every maintained branch in a sync commit.
