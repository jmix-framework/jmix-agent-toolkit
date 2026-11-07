---
name: jmix-ide-static-analysis
description: "Gate-1 static checks for Jmix 1.x (Classic UI). PRIMARY when connected: run a Jmix-aware IDE/semantic inspection (e.g. JetBrains get_file_problems) on every file you created/edited — it catches the screen-descriptor defects a compiler cannot (unresolved msg://, invalid property paths, missing data containers). Fall back to compileJava plus mechanical descriptor checks when no inspection is available. Read before relying on any static check."
---

# Static analysis (Gate 1)

Stack: Jmix 1.x (verified on 1.4.4), Classic UI: XML screen descriptors
(`<window xmlns="http://jmix.io/schema/ui/window">`, Studio names them
`<entity>-browse.xml` / `<entity>-edit.xml`), `menu.xml`, Java controllers in `io.jmix.ui`.

Gate 1 = every file you created or edited passes a static check before you move
on. **Run the IDE inspection first when it is connected; fall back to compile +
mechanical descriptor checks when it is not.**

## 1. Semantic / IDE inspection — PRIMARY when connected

If you have a Jmix-aware IDE/semantic inspection (e.g. JetBrains
`get_file_problems`), run it PER FILE on every `.java` and especially every screen
descriptor and `menu.xml` you touched — this is your primary Gate-1 check. It is the
only STATIC catch for the descriptor defects a compiler cannot see: unresolved `msg://`
keys, invalid property paths, missing data containers, broken component bindings (and
it flags the same Java errors a compile would). Rules when you use one:

- **Check that the IDE's Jmix plugin supports the project's Jmix version.** The Jmix
  inspections come from the Jmix Studio plugin; a plugin build that does not handle
  this Jmix 1.x project reports nothing Jmix-specific. Prove it with the known-defect
  probe below before you trust a clean result.
- **Read the connected tool schema before choosing the project.** When a call
  supports `projectPath`, pass the absolute root of the intended open project on
  every call. Use the server's documented project-discovery mechanism if needed;
  do not assume omitting the argument will return a list. Some servers expose no
  project argument: do not invent one. Confirm the intended project with a known
  diagnostic as described below, or report the inspection unavailable.
- **Surface WARNINGS, not just errors.** Jmix-plugin findings (unresolved
  `msg://`, bad fetch/entity refs, broken bindings) are typically reported as
  WARNINGS — an errors-only view looks clean when it is not. Include warnings and
  treat Jmix-inspection / unresolved-reference warnings as blockers.
- **Never trust an EMPTY result you did not confirm.** An inspection that
  silently targeted the wrong project/module returns "no problems" on a file it
  never looked at — that is false-clean. Require a result for every requested path;
  a batch omission or timeout means UNVERIFIED, not clean. Prefer individual calls
  for descriptors. Probe with a known defect: inspect a disposable descriptor copy
  with a deliberately invalid `msg://` key in an IDE-indexed resource directory,
  confirm the defect is reported, then remove only that probe. Leave the original
  unchanged.
- **The inspection needs the project opened as a STANDALONE Gradle project** (its
  own root, not a subdirectory of another open project) — a nested path resolves to
  the wrong module and returns generic noise (e.g. "URI is not registered"), not
  Jmix findings. Even when it works it can miss unknown components / bad attributes,
  so keep the mechanical descriptor checks alongside it.
- **Fallback decision rule.** If the inspection returns "URI is not registered" or
  only generic/non-Jmix findings on a screen descriptor you just edited, treat the
  inspection as UNAVAILABLE for this run — do NOT call the file clean. Fall through to
  `compileJava` + the mechanical descriptor checks.
- **Never trust an ALL-ERRORS result either — the IDE may not index the file.**
  If the inspection reports "Cannot resolve symbol" for practically EVERY symbol,
  including JDK types such as `String`, `List`, `Map`, that signature means "the
  IDE is not indexing this file" — the result is garbage, not a broken file. The
  bogus findings carry severity ERROR, so an errors-only filter does not remove
  them; do NOT fix code from them. Disregard the whole result and fall back to
  `compileJava` + the mechanical descriptor checks. For an XML-only edit, the analogue
  is "message not found" on `msg://` keys that grep DOES resolve in
  `messages_*.properties`. The most common cause is a git worktree nested under the
  project root while the IDE is opened on the main checkout. Mechanical precondition
  for any file type: `git rev-parse --show-toplevel` run in the edited file's
  directory must equal the confirmed IDE project root (`projectPath` when supported)
  — if it differs, the inspection of that path is not authoritative. The same
  signature also arises from a file outside any source root, a never-imported Gradle
  project, an IDE project JDK the Gradle 7.x import cannot use (see
  `jmix-verify-bootrun`), or indexing lag right after files were written from outside
  the IDE.
- **A compile-only fallback leaves debt — record it.** When no inspection is
  connected, LIST the files that got only `compileJava` in your completion report,
  and re-inspect them the next time a session has the inspection available.

### Jmix semantic findings only this inspection catches — fix them

These are TRUE positives. They are invisible to `compileJava`, to the mechanical
checks, and to a green `clean test` (in 1.x the context-load test does not open
screens):

- **Unresolved `msg://` key** — renders as the bare key at runtime, no exception.
- **Invalid property path / missing data container** in a screen descriptor.
- **Unfetched-attribute risk** on a property a screen reads but the fetch plan omits
  (see `jmix-configure-fetch-plan`).
- **`Result of DataManager.save() is not used`** — `save()` re-selects the entity
  after persisting; when the caller discards the result that reload is wasted work.
  See `jmix-create-service`.

### Known false positives — do NOT chase these

| Finding | Why it is not a defect |
|---|---|
| "Method is never used" on `@ConfigurationProperties` getters/setters | called by Spring through reflection |
| "Method is never used" on entity getters/setters | called by Jmix/JPA through reflection and by screen descriptors |
| "Unused property" on an i18n key | normal when the screen that references it does not exist yet |
| "Field is never assigned" on an `@Autowired` component field of a screen controller | injected from the descriptor by id at screen creation |
| "Method is never used" on `@Subscribe` / `@Install` handlers | invoked by the screen framework |
| "Field can be converted to a local variable" in a test class | fields hold `@Autowired`/fixture state across methods |

### What NO static check covers

- A theme variable or style name that does not exist in the app's Classic UI theme
  (Halo/Hover/Helium SCSS): the style silently does not apply. Only looking at the
  rendered screen catches it. See `jmix-style-ui`.
- Code paths that only run outside a user request — schedulers, `@Async`, message
  listeners. See `jmix-run-background-code`.

## 2. Compile — Java ground truth, and floor when no inspection

```bash
./gradlew --no-daemon compileJava      # with JAVA_HOME = JDK 11 or 17 (see jmix-verify-bootrun)
```

Authoritative for `.java`: unresolved symbols, wrong imports/packages, type
mismatches, bad handler signatures. Run it regardless — it is cheap and is the
precondition for Gate 2. But **compileJava is BLIND to XML descriptors and to the
controller-to-descriptor wiring.** These all compile clean and throw only when the
screen opens (verified on 1.4.4):

- an unknown element in `<layout>` → `GuiDevelopmentException: Unknown component: <name>`;
- an `@Autowired` component field whose name matches no component id →
  `DevelopmentException: Unable to find an instance of type '...' named '<field>'`;
- a `@Subscribe("<id>")` / `@Install(to = "<id>")` target that does not exist;
- an `msg://` typo (no exception at all: the bare key renders).

A clean compile proves NOTHING about any `.xml`, and a 0-byte `.java`/`.xml` also
compiles clean — confirm written files are non-empty.

## 3. Mechanical descriptor checks — floor when no inspection

Run them from the project directory; each maps to a defect that passes a clean compile
and a green context-load test.

The `find` checks are pass/fail (any output = a defect to fix); the `grep` checks only
SURFACE candidates — explain every hit.

```bash
# screen descriptors of this project
DESC=$(grep -rl 'xmlns="http://jmix.io/schema/ui/window"\|xmlns="http://jmix.io/schema/ui/fragment"' src/main/resources --include='*.xml')
# package line on every .java
find src/main/java -name '*.java' | while read f; do grep -q '^package ' "$f" || echo "MISSING package: $f"; done
# every @UiDescriptor file exists next to the controller's package under src/main/resources
grep -rn '@UiDescriptor' src/main/java --include='*.java'
# every @Autowired COMPONENT field name = a component id in its descriptor
# (bean fields such as Notifications, Messages, ScreenBuilders in the list need no id)
grep -rn -A1 '@Autowired' src/main/java --include='*.java' | grep -E 'private (io\.jmix\.ui\.component\.)?[A-Z][A-Za-z]*(<[^>]*>)? [a-z][A-Za-z0-9]*;'
grep -ho 'id="[^"]*"' $DESC | sort -u
# @Subscribe("id") / @Install(to = "id") targets exist in the descriptor
grep -rn '@Subscribe("\|@Install(to = "' src/main/java --include='*.java'
# every @NotNull / nullable=false needs an entity-layer default (see jmix-create-entity)
grep -rn 'nullable = false\|@NotNull' src/main/java --include='*.java'
# loader query parameters must be bound (:container_* / :component_* by dataLoadCoordinator) or set in code
grep -n ':[a-zA-Z_]' $DESC
# CREATE => MODIFY in every role; @MenuPolicy lists leaf item ids (see jmix-create-resource-role)
grep -rn 'CREATE\|MODIFY\|VIEW\|@MenuPolicy\|@ScreenPolicy' src/main/java --include='*Role.java'
# no Flow UI / Jmix 2+ symbols in a Classic UI project
grep -rnE 'io\.jmix\.flowui|io\.jmix\.securityflowui|jakarta\.|@ViewComponent|@ViewController' src/main/java --include='*.java'
# every msg:// key must resolve (brief msg://key -> <descriptor package>/key; msg:///key -> key)
grep -rhoE 'msg://[^"<> ]*' src/main/resources --include='*.xml' | sort -u
grep -rn 'mainMsg://' src/main            # not resolved in Jmix 1.x: must be empty
# no BOM / leading content before the XML tag
for f in $DESC src/main/resources/*/*/*/menu.xml; do [ -f "$f" ] && { LC_ALL=C head -c 1 "$f" | grep -q '<' || echo "BAD XML prolog/BOM: $f"; }; done
# no 0-byte source file
find src/main -type f \( -name '*.java' -o -name '*.xml' \) -size 0
```

These are MANDATORY whenever you have neither an inspection nor a screen-opening test
/ render walk — they are then your ONLY catch for those defects.

## Per-file loop

For each file you created or edited: inspection-if-connected (else compile) → fix
every error and every unresolved-reference / Jmix-inspection warning → repeat until
clean. Run it on EVERY file, not a sample. After the last edit, a full `compileJava` is
the precondition for Gate 2 (`clean test`, see `jmix-verify-bootrun`).

For verifying a symbol BEFORE you type an unfamiliar API, see `jmix-verify-api-symbol`.
