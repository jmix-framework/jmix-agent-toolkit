---
name: jmix-ide-static-analysis
description: "Gate-1 static checks. PRIMARY when connected: run a Jmix-aware IDE/semantic inspection (e.g. JetBrains get_file_problems) on every file you created/edited — it catches the *-view.xml defects a compiler cannot (unresolved msg://, invalid property paths, missing data containers). Fall back to compileJava plus mechanical descriptor checks when no inspection is available. Read before relying on any static check."
---

# Static analysis (Gate 1)

Every file you created or edited passes a static check before you move on.

## Steps

1. **Choose the path by the connected tools.** If a Jmix-aware IDE or semantic
   inspection is connected (for example JetBrains `get_file_problems`), it is
   your primary check: run it per file on every `.java` and especially every
   `*-view.xml` you touched. Read **When a semantic inspection tool is
   connected** below. If none is connected, or it turns out to be unavailable,
   compile (step 2) is your check for `.java`. Run steps 2 and 3 in both
   cases.
2. **Compile.** Run it in every case: it is cheap and is the precondition for
   Gate 2.
   ```bash
   ./gradlew --no-daemon compileJava
   ```
   It is authoritative for `.java`: unresolved symbols, wrong imports or
   packages, type mismatches, bad handler signatures. It does not read XML
   descriptors: an enum bound to `entityComboBox` instead of `comboBox`, an
   `itemsQuery` without `:searchString`, a `msg://` typo, or an action that
   opens a non-existent view id compiles clean and then throws at render time.
   A clean compile proves nothing about any `.xml`.
3. **Run the mechanical descriptor checks** (below) in every case. An
   inspection that works can still miss unknown components and bad
   attributes.
4. **Run the per-file loop** (below) on every file.
5. **Record compile-only files.** When no inspection was available, list the
   files that got only `compileJava` in your completion report, and re-inspect
   them the next time a session has the inspection. A green compile misses
   every Jmix semantic finding (unresolved `msg://` keys, invalid property
   paths, missing data containers, unfetched attributes).

To verify a symbol before you type an unfamiliar API, see
`jmix-verify-api-symbol` — the cheapest and earliest defense against
invented names.

## Mechanical descriptor checks

Run them from the project directory. Each one maps to a defect that passes a
clean compile and even a green `clean test`. Run them in every case. When you
have neither an inspection nor a Gate 3 render walk, they are the only check for
these defects.

- The `find` checks are pass/fail: any output is a defect to fix.
- The `grep` checks only show candidates. A hit is not automatically a failure,
  but you must explain every hit: each `msg://` key must resolve in a
  `messages_*.properties`; each `= :` loader parameter must be bound or guarded;
  each required field must have the right default (see the comment below and
  **Required-field defaults** in `jmix-create-entity`).
- A `*-view.xml` must start with an XML tag, `<?xml ...?>` or `<view ...>`. A
  BOM, whitespace, or other content before the first `<` is a defect; it can
  show as `SAXParseException: Content is not allowed in prolog`.

```bash
# package line on every new .java (missing → view-registry / import breakage)
find src/main/java -name '*.java' | while read f; do head -1 "$f" | grep -q '^package ' || echo "MISSING package: $f"; done
# required fields: one whose default value the requirements define needs an
# entity-layer default (not InitEntityEvent); one the user enters needs none
grep -rn "nullable = false\|@NotNull" src/main/java --include='*.java'
# manual :param loaders must be bound (:container_* / :component_*) or guarded
grep -rn "= :" src/main/resources --include='*-view.xml'
# CREATE ⇒ MODIFY in every role; @MenuPolicy lists leaf item ids
grep -rn "CREATE\|MODIFY\|VIEW" src/main/java --include='*Role.java'
# itemsQuery must reference :searchString (or switch to itemsContainer)
grep -rn "itemsQuery" src/main/resources --include='*-view.xml'
# no raw Vaadin Dialog in a Jmix view
grep -rn "com.vaadin.flow.component.dialog.Dialog" src/main/java --include='*.java'
# every msg:// key must resolve in a messages_*.properties (else literal key renders)
grep -rhoE 'msg://[^"<> ]+' src/main/resources --include='*.xml' | sort -u
# no BOM / leading content before the XML tag (else SAX "Content is not allowed in prolog")
find src/main/resources -name '*-view.xml' | while read f; do LC_ALL=C head -c 1 "$f" | grep -q '<' || echo "BAD XML prolog/BOM: $f"; done
# no 0-byte source file (empty role drops policies; empty *-view.xml poisons registry)
find src/main -type f \( -name '*.java' -o -name '*.xml' \) -size 0
```

## Per-file loop

For each file you created or edited: inspection if connected (else compile) →
fix every error and every unresolved-reference or Jmix-inspection warning →
repeat until clean. Run it on every file, not a sample: the defects that
survive are the ones you were sure about and never checked. If the inspection
reports "is never used", "unused", "is not used", or "can be converted to a
local variable", read **When the inspection reports an unused or
can-be-converted finding** below before you change code. After the last edit, a full `compileJava` is the precondition for Gate 2
(`clean test`).

## What no static check covers

- A CSS custom property that does not exist in the app's active theme. A
  `--lumo-*` variable in an Aura-themed app is undefined: the browser silently
  falls back (color → inherited, `border-radius` → 0), nothing errors, and every
  gate stays green. Only reading the computed style in a real browser catches
  it. See `jmix-style-ui`.
- Code paths that run only outside a user request — schedulers, `@Async`,
  message listeners. See `jmix-run-background-code`.

## Forbidden

- Calling a file clean from an empty inspection result you did not confirm, or
  from a batch omission or timeout.
- Reading only errors from the inspection: Jmix findings come as warnings.
- Calling a file clean when the inspection returned "URI is not registered" or
  only generic, non-Jmix findings on a `*-view.xml`.
- Fixing code from a result where "Cannot resolve symbol" covers almost every
  symbol, including JDK types — the IDE is not indexing the file.
- Inventing a project argument for an inspection tool that has none, or
  assuming that leaving the argument out returns a project list.
- Changing the original descriptor for a `msg://` probe, or leaving the probe
  copy behind.
- Treating a clean `compileJava` as proof about any `.xml`.
- Skipping the mechanical checks, even when an inspection is connected.
- Checking a sample of files instead of every file, or leaving compile-only
  files out of the completion report.
- Discarding the result of `DataManager.save()` — use `saveWithoutReload()`.
- Setting the default of a required field whose default the requirements define
  in `InitEntityEvent` or only in a view, instead of at the entity layer.
- A `.java` file without a `package` line, a 0-byte `.java` or `.xml`, or a
  `*-view.xml` with a BOM or content before the first `<`.
- `CREATE` without `MODIFY` in a role; a `@MenuPolicy` that does not list leaf
  item ids.
- A manual `= :` loader parameter that is neither bound (`:container_*` /
  `:component_*`) nor guarded.
- `itemsQuery` without `:searchString`; a raw Vaadin `Dialog` in a Jmix view.
- Changing code because of a finding listed in **When the inspection reports an
  unused or can-be-converted finding**.

## Special cases

### When a semantic inspection tool is connected

It is the only static check for descriptor defects (unresolved `msg://` keys,
invalid property paths, missing data containers, broken bindings), and it also
reports the Java errors a compile does.

**Choose the project.** Read the connected tool's schema first. When a call
supports `projectPath`, pass the absolute root of the intended open project on
every call. Use the server's documented project-discovery mechanism if needed;
do not assume that leaving the argument out returns a list. Some servers have no
project argument: do not invent one. Confirm the intended project with a known
diagnostic (below), or report the inspection unavailable.

**The project must be open as a standalone Gradle project** (its own root, not
a subdirectory of another open project). A nested path resolves to the wrong
module and returns generic noise (for example "URI is not registered"), not
Jmix findings.

**Include warnings.** Jmix-plugin findings (unresolved `msg://`, bad fetch or
entity references, broken bindings) usually come as warnings, so an errors-only
view looks clean when it is not. Treat Jmix-inspection and
unresolved-reference warnings as blockers.

**Confirm an empty result.** An inspection that silently targeted the wrong
project or module returns "no problems" for a file it never looked at.

- Require a result for every requested path; a batch omission or timeout means
  unverified, not clean. Prefer individual calls for descriptors.
- Check a file with a known diagnostic in the intended project. If needed,
  inspect a disposable copy of a descriptor with a deliberately invalid
  `msg://` key, placed in an IDE-indexed resource directory; confirm the defect
  is reported, then remove only that probe. Leave the original unchanged.
- In an abstract descriptor with no resolvable data container, a clean
  property-path check does not prove the bindings are valid; inspect or test
  the concrete view that inherits it too.

**When the inspection is unavailable for this run.** Do not call the file
clean; fall back to `compileJava` plus the mechanical descriptor checks, and
record the file as compile-only. This applies when:

- it returns "URI is not registered" or only generic, non-Jmix findings on a
  file you know has a descriptor (a `*-view.xml` you just edited);
- it reports "Cannot resolve symbol" for almost every symbol, including JDK
  types such as `String`, `List`, `Map`. This means the IDE does not index the
  file; the result is wrong, not the file. These findings have severity ERROR,
  so an errors-only filter does not remove them; do not fix code from them and
  ignore the whole result. For an XML-only edit, the same sign is "message not
  found" on `msg://` keys that grep does find in the module's
  `messages_*.properties`.

The most common cause of the second case is a git worktree nested under the
project root (agent tools create these often) while the IDE has the main
checkout open: the file is inside the project directory, so the inspection
accepts the path and returns wrong findings instead of an error. Check before
you trust any file type: `git rev-parse --show-toplevel`, run in the edited
file's directory, must equal the confirmed IDE project root (`projectPath` when
supported). If it differs, the file is in another worktree and the inspection
of that path does not count. The same sign also comes from a file outside any
source root, a Gradle project that was never imported, or indexing lag right
after files were written from outside the IDE.

**Findings to fix.** These are true positives. `compileJava`, the mechanical
checks, and a green `clean test` do not catch them:

- **Unresolved `msg://` key** — renders as the literal key at runtime.
- **Invalid property path or missing data container** in a `*-view.xml`.
- **Unfetched-attribute risk** on a property a view reads but the fetch plan
  omits (see `jmix-configure-fetch-plan`).
- **`Result of DataManager.save() is not used; use saveWithoutReload()`** —
  `save()` selects the entity again after persisting; when the caller discards
  the result, that reload is wasted work. See `jmix-create-service`.

### When the inspection reports an unused or can-be-converted finding

These findings are expected noise. Say that you understand them and move on:

| Finding | Why it is not a defect |
|---|---|
| "Method is never used" on `@ConfigurationProperties` getters/setters | called by Spring through reflection |
| "Method is never used" on entity getters/setters | called by Jmix/JPA through reflection and by view descriptors |
| "Unused property" on an i18n key | normal when the view that references it does not exist yet (e.g. a detail-view title key added while building the list view) |
| "Field can be converted to a local variable" in a test class | fields hold `@Autowired`/fixture state across methods |
| "Result of `DataManager.save()` is not used" in a test that keeps the entity for cleanup | a false positive only if the returned instance is used (e.g. added to a cleanup list); if the result is really discarded, it is a real finding: use `saveWithoutReload()` |
