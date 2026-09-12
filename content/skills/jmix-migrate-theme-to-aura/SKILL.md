---
name: jmix-migrate-theme-to-aura
description: Switch a project that came from Jmix 2.x over to the Aura theme. Studio's 2.x→3.x migration deliberately keeps Lumo and there is no automated conversion, so every step here is manual. Each step has a SILENT failure mode — the app boots, compiles, and passes a green clean test while still rendering Lumo, or renders Aura tokens on top of Lumo components.
---

# Migrate a Jmix 2.x project's theme to Aura

Applies after Studio's platform upgrade to Jmix 3.x, when the project should use
Aura instead of Lumo.

## Step 0 — know what the upgrade did and did NOT do

Studio's automatic migration updates the BOM, the Gradle plugin and wrapper,
dependencies, and some configuration. On theming it touches three places:

```diff
  // <App>Application.java
+ @StyleSheet(Lumo.UTILITY_STYLESHEET)                  // + the Lumo import
  @Theme(value = "<app>")                               // left alone, still Lumo

+ com.vaadin.experimental.themeComponentStyles=true     # new vaadin-featureflags.properties

- {"parent": "jmix-lumo", "lumoImports":["typography","color",...]}   # theme.json,
+ {"parent": "jmix-lumo"}                                            # but see below
```

All of it keeps the project **on Lumo**. The feature flag is a **Lumo
compatibility shim** that keeps Lumo component styling working on Vaadin 25, and
the utility stylesheet is Lumo's too — Step 2 removes both. Aura is offered only
when *creating* a new project; nothing below happens automatically.

**The `theme.json` rewrite is not guaranteed.** `lumoImports` is dead in
Vaadin 25 either way — flow-server's
`plugins/application-theme-plugin/theme-generator.js` still reads it at 24.9.x
and no longer mentions it at 25.1.x — but Studio does not always strip it.
Observed removed in a project whose theme sat under `src/main/frontend/themes/`
and left untouched in two at root-level `frontend/themes/`; that the cause is the
layout is a guess, not something confirmed against Studio. It makes no
difference here, since Step 3 deletes the folder — just do not read a surviving
`lumoImports` as evidence that the platform upgrade did not run.

Confirm where you actually are before changing anything:

```bash
grep -rn "@Theme\|@StyleSheet" src/main/java --include='*.java'
# The Lumo theme folder is at src/main/frontend/themes/<app>/ in newer 2.x
# projects and at frontend/themes/<app>/ in older ones — locate it, don't assume:
find . -name theme.json -not -path '*/generated/*' -not -path '*/node_modules/*' \
       -not -path '*/build/*' -print -exec cat {} +
cat src/main/resources/vaadin-featureflags.properties 2>/dev/null
```

Keep that folder path — Step 3 deletes it and `@Theme(value = "<app>")` names it.

## Step 1 — take the scaffold from a real Aura project, do not hand-write it

**First look for an Aura project already on this machine.** This needs no Studio,
and on a developer's laptop it is usually a hit:

```bash
find ~ -maxdepth 8 -type d -path '*META-INF/resources/themes/*-aura' \
       -not -path '*/build/*' -not -path '*/node_modules/*' 2>/dev/null
```

Treat a hit as a clean source only if its `<app>.css` is still the untouched
`/* Define your styles here */`; otherwise you inherit someone's project CSS.
Diff two hits against each other if you have them — pristine scaffolds are
byte-identical apart from that one file. A source project on a different patch
version is fine (this is generated CSS, not pinned API — a 3.0.1 scaffold in a
3.0.2 project is what the observations here are based on), but say so in your
report.

Otherwise create a throwaway Jmix 3 project in Studio choosing **Aura**, or use
any project already created that way, and copy its theme folder. The generated
Aura CSS is much richer than a translated Lumo file — app-layout insets and
radii, surface gradients, the user-menu grid, the initial layout. Hand-porting
the old Lumo boilerplate reproduces none of it.

```
src/main/resources/META-INF/resources/themes/<app>-aura/
├── styles.css                     # @import list only
├── <app>.css                      # "/* Define your styles here */"
└── view/
    ├── main-view.css
    ├── main-view-top-menu.css
    └── login-view.css
```

Copy the folder, rename `<source-app>.css` to `<app>.css`, and fix that one
`@import` line in `styles.css`. A fresh project also ships an `<app>-lumo`
sibling; keeping it makes switching back a one-line change.

**Note the location.** Aura themes live under
`src/main/resources/META-INF/resources/themes/`, not under the `frontend/themes/`
tree the Lumo theme used, wherever that sat.

## Step 2 — load Aura from the app shell, not from theme.json

`theme.json`'s `parent` is the deprecated Lumo-era mechanism. `Aura` and
`JmixAura` are plain classes holding a `STYLESHEET` constant — neither
implements `AbstractTheme`, so neither can ever be a `@Theme(themeClass=…)` or a
`theme.json` parent.

```java
@Push
@StyleSheet(Aura.STYLESHEET)                        // com.vaadin.flow.theme.aura.Aura
@StyleSheet(JmixAura.STYLESHEET)                    // io.jmix.flowui.theme.aura.JmixAura
@StyleSheet("themes/<app>-aura/styles.css")         // your own CSS, loaded last
@SpringBootApplication
public class MyApplication implements AppShellConfigurator {
```

Order matters: the theme stylesheets come before your own. **Delete the `@Theme`
annotation** and its import — with the folder gone it has nothing to resolve,
and it is deprecated in Vaadin 25 anyway.

**Delete `@StyleSheet(Lumo.UTILITY_STYLESHEET)` and the `Lumo` import too** —
the upgrade added them, and they load a Lumo stylesheet next to Aura. Aura has
no counterpart: in `vaadin-aura-theme` 25.1.x the `Aura` class exposes only
`STYLESHEET`, and `aura.css` defines no utility classes at all, just
`.aura-accent-*`, `.aura-surface*` and the `.v-error` / `.v-success` state
classes. Check whether you actually use any before dropping it:

```bash
grep -rn "LumoUtility" src/main/java --include='*.java'
grep -rhoE 'classNames?="[^"]*"' src/main/resources --include='*.xml' | sort -u
```

Lumo utility names (`p-m`, `gap-s`, `flex`, `text-secondary`, …) stop resolving
silently — port them into your own theme CSS first. A project that uses none, as
all three projects this skill has been run against did, will notice nothing.

**Do not set `"parent": "jmix-aura"` in theme.json.** The `@StyleSheet`
declarations above are the documented way to load Aura; the parent chain is not.
On top of that, in `jmix-flowui-themes` 3.0.1 and 3.0.2 the packaged `jmix-aura`
folder contains no `styles.css` (only `jmix-aura.css`), so the parent chain also
fails outright — check this for your own version, since a later release may add
that file:

```
java.nio.file.NoSuchFileException: .../frontend/generated/jar-resources/themes/jmix-aura/styles.css
Caused by: RuntimeException: Unable to read theme file from styles.css
```

Adding your own `styles.css` shim for `jmix-aura` silences that crash but does
not switch the theme, so it is not a substitute for Step 2.

## Step 3 — delete the old theme wiring

```bash
git rm -r <theme folder from Step 0>   # e.g. src/main/frontend/themes or frontend/themes
git rm src/main/resources/vaadin-featureflags.properties
```

Removing the feature flag is required, not cleanup. `themeComponentStyles`
injects **Lumo** component styles; under Aura it produces a half-styled UI that
looks plausible enough to miss:

- text fields lose their borders (underline-only)
- checkboxes render blank
- icons render as empty squares
- `window.Vaadin.featureFlags.themeComponentStyles` reads `true` in the console

Do NOT read `--_lumo-vaadin-*-inject` rules in `document.adoptedStyleSheets` as
the symptom — they are present under Aura too, with the flag off. See **Verify**.

If the file holds other flags, drop only the `themeComponentStyles` line.

## Step 4 — clean the frontend bundle (mandatory, and easy to skip)

```bash
./gradlew clean vaadinClean
```

This is the documented post-migration step. Without it the prebuilt
`src/main/bundles/dev.bundle` from the Lumo era is reused and **keeps serving
Lumo component styles**, while Vaadin logs the reassuring:

```
BundleValidationUtil : A development mode bundle build is not needed
```

`vaadinClean` removes `src/main/bundles`, `node_modules`, `.vaadin`, and usually
the generated frontend; the next start rebuilds (npm install + bundle, a minute or
two, logged as `Development frontend bundle built`). Deleting
`src/main/frontend/generated` alone is NOT enough.

It does not always get everything: on a root-level `frontend/` layout it left
`frontend/generated` in place. Verify, and delete by hand whatever survives —
these paths are all gitignored, so this is safe:

```bash
./gradlew clean vaadinClean
# Run this BEFORE starting the app — see below.
for d in src/main/bundles node_modules .vaadin frontend/generated src/main/frontend/generated; do
  [ -e "$d" ] && echo "STILL PRESENT: $d  (delete it)"
done
```

Order matters: a successful start legitimately recreates `src/main/bundles` (and
`node_modules`), so the same loop run afterwards reports them and means nothing.
Check between `vaadinClean` and the first start, or you will chase a phantom.

You want the next start to log `A development mode bundle build is needed`. If it
logs `not needed`, something stale survived.

## Step 5 — port your own CSS to Aura tokens

Every `--lumo-*` name is undefined under Aura and fails silently. The two
families are not name-for-name equivalents — translate by meaning:

| Lumo | Aura |
|---|---|
| `--lumo-font-size-*` | `--aura-font-size-xs…xl` (5 steps, no xxs/xxl/xxxl) |
| `--lumo-space-*` | `--vaadin-padding-*` (margins/padding), `--vaadin-gap-*` (gap) |
| `--lumo-body-text-color` | `--vaadin-text-color` |
| `--lumo-secondary-text-color` | `--vaadin-text-color-secondary` |
| `--lumo-header-text-color` | `--vaadin-text-color` (approximate: Aura has no separate header-text token) |
| `--lumo-contrast-10pct` (borders) | `--vaadin-border-color-secondary` |
| `--lumo-shade-5pct` (subtle fill) | `--vaadin-background-container` |
| `--lumo-size-*` (control height) | **no equivalent** |

Aura has no control-height scale and no contrast scale. Where you relied on
`--lumo-size-*`, define your own token in the project stylesheet rather than
inventing an `--aura-` name.

Global density comes from two root numbers rather than three independent
scales, so a Lumo "compact preset" collapses to overriding these two knobs:

```css
html {
  --aura-base-font-size: 14;   /* default 14; drives the font-size scale      */
  --aura-base-size: 16;        /* default 16; drives the gap and padding scales */
}
```

Aura ships no compact preset, and there are no canonical "compact" values —
lower the two defaults to taste and check the result in a browser. Note that
unlike Lumo you cannot shrink spacing independently of control sizing.
Enumerate before guessing any name — see `jmix-style-ui`.

## Step 6 — audit theme variants and view class names

**Variants are theme-specific and compile either way.** Jmix 3.0 removed
`always-float-label`, `contained`, `outlined`; support now depends on the active
theme. Under Aura, `contrast` is styled only as
`[theme~='badge'][theme~='contrast']`, so `themeNames="contrast"` on a button
does nothing at all.

```bash
grep -rn "themeNames=" src/main/resources --include='*.xml'
grep -rn "LUMO_" src/main/java --include='*.java'
```

**Class names the Aura CSS keys off must exist in your descriptors.** The
generated `main-view.css` styles the header only through the app-layout class:

```css
vaadin-app-layout.jmix-main-view-app-layout:not([primary-section='navbar']) .jmix-main-view-header { … }
```

A 2.x `main-view.xml` has a bare `<appLayout>`. Without the class every header
rule silently no-ops — no surface, no border, no radius, no padding, leaving the
drawer toggle floating on the page background:

```xml
<appLayout classNames="jmix-main-view-app-layout">
```

Diff your `main-view.xml` against the fresh project's. The rules above are for
the drawer-based MainView; a project using the horizontal menu keys off the
`jmix-main-view-top-menu-*` classes in `main-view-top-menu.css` instead.

Other 3.x changes there are optional but visible: a header `<userMenu>`
replacing the footer `<userIndicator>` (its renderer installs live in
`MainView.java` and the `user-menu-*` classes are already styled), and
`<listMenu themeNames="toggle-reverse"/>`, which moves the menu toggles to the
trailing edge — purely cosmetic, and adopt it only if you want that look.

**Adopting `<userMenu>` in a non-English app: do not copy the reference's message
keys.** The generated main view refers to two *framework* keys,
`actions.logout.text` and `userMenu.substituted`, and `jmix-translations-<lang>`
does not necessarily carry them — `jmix-translations-es` 3.0.1 ships
`actions.logout.description` but no `actions.logout.text`, so the menu item
silently renders "Log out" in a Spanish app.

Do NOT patch that with a narrow project override at
`src/main/resources/io/jmix/flowui/messages_<lang>.properties`. `JmixMessageSource`
resolves each basename through `Resources.getResource(...)`, which returns a
SINGLE resource — so such a file *replaces* the jar's bundle rather than merging
into it, and every key you did not copy falls through to the English default
bundle. (Mechanism read from the 3.0.2 sources jar, not confirmed by experiment.)

Give the action a project-owned key in the view's own message group instead:

```xml
<action id="logout" text="msg://logout.text" type="logout"/>
```

and add `<view.package>/logout.text` to every locale file — see
`jmix-add-i18n-keys`. Omit the reference's substitute-user item unless the app
actually wants user substitution; it is a second consumer of an untranslated
framework key, and it grants a real capability rather than a cosmetic one.

## Verify — in a browser, on computed values

Compile, static analysis and `clean test` all pass while the app still renders
Lumo. They prove nothing here. Start the app and check:

```js
// 1. Aura tokens must resolve. Empty string = Aura CSS is not loaded at all.
getComputedStyle(document.documentElement).getPropertyValue('--aura-base-size')

// 2. The three stylesheets must be linked, in this order.
[...document.querySelectorAll('link[rel=stylesheet]')].map(l => l.getAttribute('href'))
// ./aura/aura.css , ./themes/jmix-aura/jmix-aura.css , ./themes/<app>-aura/styles.css

// 3. No Lumo STYLING left. Test for real Lumo rules, not for the substring
//    "_lumo-vaadin" — see the warning below.
window.Vaadin.featureFlags.themeComponentStyles          // must be false
document.adoptedStyleSheets
  .map(s => [...s.cssRules].map(r => r.cssText).join('')).join('')
  .match(/--lumo-[a-z-]+\s*:/)                           // must be null
```

**The component test is the primary check** — tokens can resolve while components
still render Lumo. Compare against the fresh Aura project: a text field's
`[part="input-field"]` should have a real border width and Aura's radius
(`1px` / `9px` on 25.1.x), not `0px` / Lumo's `4px`. Read the pair off your
reference project rather than trusting those numbers — they are theme CSS and
can move between patch releases. If tokens resolve but components still look
Lumo, you skipped Step 4.

**Never test `adoptedStyleSheets` for `_lumo-vaadin`.** That substring is present
on a correctly migrated Aura app on Vaadin 25.1.x, so it reports failure on a
success. What is actually there is a single rule on `:root::before, :host::before`
whose `transition` lists `--_lumo-vaadin-*-inject` properties: Vaadin's per-page
component-detection sentinel, which kept the legacy prefix. Two things identify
it as harmless — its token list *changes as you navigate* (`login-form-wrapper`,
`text-field`, `password-field` on the login view; `app-layout`, `drawer-toggle`,
`menu-bar` on MainView), and the sheet defines no `--lumo-*` custom properties at
all. Do not try to recognise it by length: the rule grows and shrinks with that
token list. Observed on migrated projects at 25.1.11 and 25.1.14; not yet
compared against a freshly generated Aura one.

### The login view is not enough

Everything past login needs an authenticated session, and an agent must not type
passwords into the form. That matters here because **the Step 6
`jmix-main-view-app-layout` class — the most failure-prone edit in this skill,
and a silent one — can only be verified on MainView.**

Run checks 1-3 and the component test on the login view yourself: they cover
token resolution, stylesheet order, and component borders. Then ask the user to
log in, and check the header:

```js
const h = getComputedStyle(document.querySelector('.jmix-main-view-header'));
[h.borderBottomWidth, h.borderStartStartRadius]   // ['1px','15px'], not ['0px','0px']
document.querySelector('vaadin-app-layout').classList.contains('jmix-main-view-app-layout')
```

`0px` / `0px` means the class is missing and every header rule is a no-op. While
logged in, also walk the list views for an error overlay, a raw `msg://` caption,
and a clean server log — and re-run check 3 there, since its token list differs
per page.

## Forbidden

- `"parent": "jmix-aura"` in `theme.json`, or a hand-written `styles.css` shim
  for the packaged `jmix-aura` folder.
- Keeping `@Theme` together with the Aura `@StyleSheet` declarations.
- Keeping `@StyleSheet(Lumo.UTILITY_STYLESHEET)` after the switch, or looking
  for an `Aura.UTILITY_STYLESHEET` to replace it with — there is none.
- Leaving `com.vaadin.experimental.themeComponentStyles=true` enabled.
- Starting the app without `./gradlew clean vaadinClean` and concluding the
  theme "did not change anything".
- Translating a `--lumo-` name to an `--aura-` prefix and assuming it exists.
- Hand-writing the Aura view CSS instead of copying the generated scaffold.
- Calling the migration done on a green compile or `clean test` — neither
  renders a page.
- Treating `_lumo-vaadin` in `adoptedStyleSheets` as proof the migration failed;
  it is present under Aura too.
- Overriding a framework bundle at
  `src/main/resources/io/jmix/<module>/messages_<lang>.properties` to supply one
  missing translation — it shadows the whole bundle.
- Calling the migration verified from the login view alone — the MainView header
  rules are untested until someone logs in.
