---
name: jmix-verify-api-symbol
description: Before typing a class, enum constant, inner-class event, method, XML element/attribute, or icon name you have not personally verified in this Jmix 1.x project, confirm it exists in the 1.x API (Classic UI). Costs seconds and prevents the most expensive class of failures (Flow UI or Jmix 2+/3 symbols, jakarta packages, invented icons, wrong package paths). Checks = javap on the project's own resolved classpath, the 1.4 docs, grep of a working call site; IDE symbol search when available.
---

# Verify API symbols before you type them

Stack: Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui`, Vaadin 8).

A top cause of failed runs is confidently typed API names that do not exist —
they look right, survive typing, then break compile or, worse, fail only when the
screen opens. In a Jmix 1.x project the most common source is not invention but the
WRONG GENERATION: Flow UI / Jmix 2+/3 names (`io.jmix.flowui`, `@ViewController`,
`DialogWindows`, `VaadinIcon`, `jakarta.*`) that are real elsewhere and absent here.
Most public examples and model memory describe Jmix 2+/3. Run this check BEFORE
writing any symbol you have not already seen in this project's source tree.

## When to run

Before typing any of:

- An icon name (`icon="..."` in XML, `JmixIcon.X` in Java)
- A class qualified by a guessed package ("is `Notifications` in `io.jmix.ui` or
  `io.jmix.ui.notifications`?")
- An event inner class ("does `Button.ClickEvent` exist?")
- A builder-style method ("`.editEntity()` or `.withEntity()` on
  `screenBuilders.editor(...)`?")
- An XML element or attribute in a screen descriptor (`caption` vs `text`,
  `entityComboBox` vs `entityPicker`)
- A Jmix action type id or a security-role enum constant you have not used yet

Skip it only when you can point at the same exact symbol already in use in this
project's `src/`.

## How to verify

**Free short-circuit:** if the EXACT symbol is already used in this project's
`src/`, copy that call site — it is ground truth, no lookup needed:

```bash
grep -rn "ScreenBuilders" src/main/java --include='*.java'
grep -rn 'icon="' src/main/resources --include='*.xml'
```

For anything NOT already in the project, verify it before you type it:

1. **`javap` on the project's own resolved classpath — the check that always works.**
   It prints the real members and signatures, and it is the only check left for a
   symbol with zero call sites in the project. Build the classpath FROM THE PROJECT,
   never from "every jar in the Gradle cache": a shared cache usually also holds Jmix
   2.x/3.x jars of the same modules (`io.jmix.core:jmix-core:3.x` next to `1.4.4`),
   and a mixed classpath answers with the wrong generation's API.

   ```bash
   cat > /tmp/printcp.gradle <<'EOF'
   allprojects {
       tasks.register('printCp') {
           doLast { println configurations.runtimeClasspath.asPath }
       }
   }
   EOF
   ./gradlew -q --init-script /tmp/printcp.gradle printCp > /tmp/cp.txt   # JDK 11/17, see jmix-verify-bootrun
   javap -p -cp "$(cat /tmp/cp.txt)" io.jmix.ui.ScreenBuilders
   javap -p -cp "$(cat /tmp/cp.txt)" 'io.jmix.ui.component.Button$ClickEvent'
   ```

   `-p` also lists non-public members. The same `/tmp/cp.txt` gives the exact jar to
   read an XSD or a sources archive from.

2. **XML descriptor elements/attributes — read the XSD inside the resolved `jmix-ui`
   jar.** Screen descriptors are validated against `io/jmix/ui/screen/window.xsd`,
   `layout.xsd`, `data.xsd`, `fragment.xsd`; `menu.xml` against `io/jmix/ui/menu/menu.xsd`.

   ```bash
   JAR=$(tr ':' '\n' < /tmp/cp.txt | grep '/jmix-ui-1\.[0-9.]*\.jar$')
   unzip -p "$JAR" io/jmix/ui/screen/layout.xsd | grep -n 'name="entityComboBox"'
   ```

   An unknown element compiles clean and fails only when the screen opens
   (`GuiDevelopmentException: Unknown component: <name>`).

3. **Sources, when the signature is not enough.** If the IDE has downloaded them, the
   sources jar sits next to the binary in `~/.gradle/caches/modules-2/files-2.1/<group>/<artifact>/<version>/`
   (`jmix-ui-1.4.4-sources.jar`). Read the version the project resolves.

4. **Docs for the project's minor version.** `https://docs.jmix.io/1.x/jmix/1.4/`
   (e.g. `ui/screens.html`, `security/resource-roles.html`,
   `localization/message-bundles.html`); replace `1.4` with the project's minor
   version. `docs.jmix.io/jmix/...` without `1.x` is the Jmix 2+/Flow UI manual —
   its examples do not apply. A docs MCP (Context7) usually indexes the current
   Jmix, not 1.x: treat its answers as Jmix 2+ unless they cite a 1.x page, and confirm
   with step 1.

5. **IDE symbol search — if available and the project is indexed.** Confirms the
   class/constant exists and its fully-qualified name.

6. **Floor: grep a known-good 1.x example and reuse only what is actually there.**
   Studio-generated screens in this project (`screen/user/*`, `screen/main/*`) are the
   canonical 1.x shapes.

**Read the version the project resolves, not the newest one cached.** Resolve the
pinned version first (`jmix { bomVersion = '...' }` in `build.gradle`, or
`./gradlew dependencies`) and read only that artifact.

Never invent and ship. If nothing confirms a symbol, do not type it — pick one you
CAN confirm, or omit the optional decoration (e.g. drop an icon attribute rather
than guess a constant).

## A close-but-not-exact doc example still confirms the symbol

When the fetched example differs from what you need only on a **plain Java or JPA**
axis — an abstract vs concrete base class, one field more or less, another property
type — it has already confirmed the API. Stop querying for a closer match.

Keep verifying only when the difference IS the Jmix API: another method name,
another package, another annotation member. Then use `javap` (step 1).

## The recurring garbage list

Symbols commonly typed into a 1.x project. NEVER type these — verify first:

| You might type | Reality in Jmix 1.x Classic UI |
|---|---|
| `jakarta.persistence.*`, `jakarta.validation.*` | `javax.persistence.*`, `javax.validation.*` (Spring Boot 2.7) |
| anything from `io.jmix.flowui.*` | Classic UI is `io.jmix.ui.*`; Flow UI in 1.x is a separate preview, not this project |
| `@ViewController`, `@ViewDescriptor`, `StandardListView`, `StandardDetailView` | `@UiController`, `@UiDescriptor`, `StandardLookup<E>`, `StandardEditor<E>` (`io.jmix.ui.screen`) |
| `@ViewComponent` on a component field | `@Autowired` (or `@Inject`); the field name must equal the component id, else `DevelopmentException: Unable to find an instance of type ... named ...` at open |
| `DialogWindows` / `dialogWindows.detail(...)` | `io.jmix.ui.ScreenBuilders`: `screenBuilders.editor(Customer.class, this).editEntity(c).withOpenMode(OpenMode.DIALOG).show()` |
| `io.jmix.flowui.Dialogs`, `io.jmix.flowui.Notifications` | `io.jmix.ui.Dialogs` (`createOptionDialog()`, `createMessageDialog()`...), `io.jmix.ui.Notifications` (`create(NotificationType)`) |
| `VaadinIcon.X`, `icon="vaadin:..."` | `io.jmix.ui.icon.JmixIcon` constants (`icon="GEARS"`, `icon="LOOKUP_OK"`) or `icon="font-icon:<com.vaadin.server.FontAwesome constant>"`; nothing checks the name before the screen opens |
| `JmixButton.ClickEvent`, `com.vaadin.flow.component.ClickEvent` | `io.jmix.ui.component.Button.ClickEvent` |
| `dataGrid.getSingleSelectedItem()` | `table.getSingleSelected()` / `getSelected()` (`io.jmix.ui.component.ListComponent`) |
| `text="..."`, `title="..."` on components/screens | Classic UI uses `caption="..."` (`value` on `label`) |
| `@ViewPolicy(viewIds = ...)`, `io.jmix.securityflowui...` | `@ScreenPolicy(screenIds = ...)`, `io.jmix.securityui.role.annotation` |
| `mainMsg://key` | not resolved by Jmix 1.4; use `msg:///key` |
| `io.jmix.core.entity.EntityStates` | `io.jmix.core.EntityStates` |
| an add-on entity's JPQL name derived from its class name | read `@Entity(name = ...)` from the jar: e.g. role assignments are `sec_RoleAssignmentEntity` |

## Cost vs benefit

A verification check takes ~1 second; a failed `compileJava` cycle costs 15–30
seconds plus error-log parsing, and a compile that passes and fails only when the
screen opens costs a whole test run or render walk. The break-even is one prevented
failure per session — run `javap` on the project classpath (step 1), the XSD (step 2)
for XML, the 1.x docs (step 4); never ship an unverified symbol.
