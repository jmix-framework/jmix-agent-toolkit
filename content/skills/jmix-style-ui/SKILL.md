---
name: jmix-style-ui
description: "Style Jmix Classic UI screens and components (Vaadin 8 themes: Helium, Halo, Hover). Read this before writing any stylename, css attribute, HtmlAttributes call, table styleProvider, or custom theme SCSS. A style name or CSS variable the active theme does not define fails SILENTLY: no error, every gate green, wrong rendering."
---

# Style Classic UI components

Stack: Jmix 1.x (verified on 1.4.4), Classic UI (Vaadin 8). Themes are compiled SCSS
(Helium, Halo, Hover), not Lumo/Aura. There is no `getStyle()`, no `classNames`, no
`addThemeVariants`, no `--lumo-*` / `--aura-*` / `--vaadin-*` here — those are Flow UI.

## Step 0 — identify the ACTIVE theme

```bash
grep -n "jmix.ui.theme" src/main/resources/application.properties
ls src/main/themes 2>/dev/null          # a custom theme lives here
grep -n "jmix-ui-themes\|themes '" build.gradle
```

- No `jmix.ui.theme.name` → **Helium** (the default, `UiThemeProperties`). The 1.4
  project template sets no theme property and depends on
  `io.jmix.ui:jmix-ui-themes-compiled` — precompiled CSS of Helium, Halo and Hover. The
  template's menu has the **Theme Settings** screen (`themeSettingsScreen`) where a user
  switches the color preset (light/dark) and size (small/medium/large).
- `jmix.ui.theme.name = halo` / `hover` → a built-in theme, still precompiled.
- `jmix.ui.theme.name = <custom>` plus `src/main/themes/<custom>/` → a project theme
  that the build compiles (below).

What the theme family gives you:

| Theme | variables you can use in your own rules |
| --- | --- |
| Helium | CSS custom properties, about 430 of them: `--primary-color`, `--secondary-color`, `--text-main-color`, `--text-secondary-color`, `--background-color`, `--border-color`, `--success-color`, `--error-color`, `--warning-color`, `--dim-color`, … They resolve at runtime and change with the light/dark preset. |
| Halo, Hover | NO CSS custom properties at all (0 in the compiled CSS). Only SCSS variables (`$v-focus-color`, `$v-background-color`, `$v-unit-size`, …), resolved when the theme is compiled. |

So `var(--primary-color)` works under Helium and resolves to nothing under Halo/Hover.
Enumerate what exists instead of guessing:

```bash
J=$(find ~/.gradle/caches -name 'jmix-ui-themes-compiled-1.4.4.jar' | head -1)
unzip -p "$J" VAADIN/themes/helium/styles.css | grep -oE '\-\-[a-z0-9_-]+:' | sort -u
# a custom theme: grep build/themes/VAADIN/themes/<name>/styles.css after a build
```

## Where styling goes — in this order

**1. A predefined style name — for looks the theme already has.** Set it with
`stylename` in XML or `setStyleName` / `addStyleName` / `removeStyleName` in Java.
Constants are in `io.jmix.ui.theme.ThemeClassNames` (`BUTTON_PRIMARY = "primary"`,
`BUTTON_FRIENDLY`, `BUTTON_DANGER`, `BUTTON_BORDERLESS`, `LABEL_H1`…`LABEL_H4`,
`LABEL_BOLD`, `LABEL_SUCCESS`, `LABEL_FAILURE`, `TABLE_NO_STRIPES`, `TABLE_COMPACT`,
`TEXTFIELD_ALIGN_RIGHT`, `LAYOUT_CARD`, `LAYOUT_WELL`, …):

```xml
<button id="confirmBtn" caption="msg://confirmBtn.caption" stylename="primary"/>
```

```java
statusLabel.addStyleName(ThemeClassNames.LABEL_SUCCESS);
```

`stylename` holds space-separated names; `setStyleName` replaces them all,
`addStyleName` appends one.

A constant compiles in any theme and does nothing if the active theme has no rule for
it. Vaadin 8 puts each style name on the widget twice — bare (`card`) and prefixed with
the widget class (`v-verticallayout-card`, `v-button-primary`, `v-label-success`) — and
the built-in themes style the PREFIXED form. Confirm the name for your component type:

```bash
unzip -p "$J" VAADIN/themes/helium/styles.css | grep -oE '\.v-button-[a-z-]+' | sort -u
# e.g. LAYOUT_CARD is styled as .v-verticallayout-card / .v-horizontallayout-card /
# .v-csslayout-card — not on a groupBox or panel
```

**2. A rule in a project theme + your own style name — preferred for anything
reusable.** Requires a custom theme (next section). Define the class in the theme mixin
and put the name on the component:

```scss
/* src/main/themes/helium-ext/helium-ext.scss */
@import "../helium/helium";

@mixin helium-ext {
  @include helium;

  .contact-count {
    font-weight: bold;
  }
}
```

```xml
<label id="contactCountLabel" stylename="contact-count"/>
```

Your own rules can use the bare name (`.contact-count`) — it is on the element.
Everything inside the mixin is compiled under `.<theme-name>` (`.helium-ext
.contact-count`), so it applies only while that theme is active.

**3. Inline CSS — last resort, for one-off or computed values.** Every component
accepts a `css` attribute in XML; in Java use the `HtmlAttributes` bean:

```xml
<label id="hintLabel" value="msg://contactsLabel"
       css="color: var(--text-secondary-color); font-style: italic"/>
```

```java
@Autowired
private HtmlAttributes htmlAttributes;

htmlAttributes.setCssProperty(contactCountLabel, HtmlAttributes.CSS.COLOR, "var(--primary-color)");
```

Both write an inline `style` on the component's root element. Inline styles do not
change with the user's theme, and `var(--...)` in them still needs a Helium-family
theme.

**Table row/cell styles** come from a style provider; the returned name lands on the
row (`<tr>` gets both `customer-without-contacts` and `v-table-row-...`) or cell, and
the CSS goes into the project theme:

```java
@Install(to = "customersTable", subject = "styleProvider")
private String customersTableStyleProvider(Customer entity, String property) {
    if (property == null && entity.getContactCount() == null) {
        return "customer-without-contacts";   // property == null: row style
    }
    return null;
}
```

```scss
.v-table-row.customer-without-contacts {
  color: var(--text-secondary-color);
}
```

A selected row repaints its cells with the selection colors, so check an unselected
row.

## Custom theme — create, wire, compile

Studio: **User Interface → New → Custom Theme**, pick a name and the base theme. By
hand, for a Helium extension named `helium-ext`:

```
src/main/themes/helium-ext/styles.scss
src/main/themes/helium-ext/helium-ext.scss
src/main/themes/helium-ext/helium-ext-defaults.scss
src/main/resources/<project package path>/theme/helium-ext-theme.properties
```

```scss
/* styles.scss — compile entry point */
@import "helium-ext-defaults";
@import "addons";
@import "helium-ext";

.helium-ext {
  @include addons;
  @include helium-ext;
}
```

```scss
/* helium-ext-defaults.scss — SCSS variable overrides */
@import "../helium/helium-defaults";
```

`addons` is generated by the build from theme add-ons; do not create it.

```properties
# helium-ext-theme.properties — server-side theme constants
@include=io/jmix/ui/theme/helium-theme.properties
```

```groovy
// build.gradle
implementation 'io.jmix.ui:jmix-ui-themes'
themes 'io.jmix.ui:jmix-ui-themes'
```

```properties
# application.properties
jmix.ui.theme.name = helium-ext
jmix.ui.theme-config = io/jmix/ui/theme/helium-theme.properties com/company/app/theme/helium-ext-theme.properties
```

- `jmix.ui.theme-config` REPLACES the built-in list (helium, halo, hover), it does not
  add to it. With only your file, `ThemeConstantsRepository` knows one theme
  (verified: `[helium-ext]`); list every theme that must stay selectable, separated by
  spaces (verified: `[helium-ext, helium]`).
- The `themes` dependency is what enables compilation: with it, the `io.jmix` Gradle
  plugin wires `compileThemes` into `classes`, so `build`, `test`, `bootRun` and `jar`
  compile the SCSS (verified with `--dry-run`; without it, `compileThemes` is not in the
  chain). The output is `build/themes/VAADIN/themes/<name>/styles.css` plus the
  built-in themes, packaged into the jar.
- While the app is running, `./gradlew compileThemes` recompiles; then hard-reload the
  browser. `compileThemes` is the only gate that reads SCSS, and it is weak: a missing
  import fails it (`Import '../helium/heliumX' ... could not be found`, `Unable to build
  theme`), but an undefined `$variable` compiles with exit code 0 (both verified).
- Helium variables are CSS custom properties: override them inside the mixin
  (`--primary-color: #0097D8; --primary-color_rgb: 0, 151, 216;`). That changes the
  LIGHT preset only — the dark preset is a separate `.helium-ext.dark { ... }` block
  with its own `--primary-color` (verified in the compiled CSS). To restyle dark, add an
  `&.dark { ... }` block; to add a preset, add `&.<preset> { ... }` and list it in
  `jmix.ui.theme.modes` (optionally `jmix.ui.theme.default-mode-to-use`).
- For Halo/Hover extensions override `$v-*` variables in `<name>-defaults.scss`
  (`$v-font-size`, `$v-unit-size`, `$v-layout-margin-*`, `$v-table-row-height`, …);
  they take effect only after recompiling.
- Branding images: replace files in `src/main/themes/<name>/branding`.

To find the class of an element you want to restyle (e.g. `.jmix-sidemenu-item-caption`),
inspect it in the browser, then add the rule to the mixin.

## Why a wrong style is invisible to every gate

A style name no rule targets, a CSS variable the theme does not define, or a rule in a
theme that is not active — none is an error anywhere. Java compiles, the descriptor
loads, `clean test` and a `@UiTest` stay green (they never render CSS), and the browser
silently falls back (`color` → inherited, `background-color` → transparent, length →
initial value).

## Verify — the COMPUTED style, in a browser

Run the app (`jmix-verify-bootrun`, Gate 3) and read computed values with a headless
browser script:

```js
getComputedStyle(document.querySelector('.v-app')).getPropertyValue('--primary-color')  // '#0097d8' after the override
document.querySelector('.v-app').className   // 'v-app helium-ext appui' -> the active theme
getComputedStyle(document.querySelector('.contact-count')).fontWeight                    // '700'
```

Select elements by your style name or the `v-<widget>-<stylename>` class. To select
by component id, set `jmix.ui.test-mode = true`: components then carry a `j-test-id`
attribute (`[j-test-id="contactCountLabel"]`). Compare against an unstyled component of the same
type — if the values match, the style did nothing. If no browser is available, say
`styling not browser-verified` instead of calling it done.

## Forbidden

- Flow UI styling (`getStyle()`, `classNames`, `addThemeVariants`, `@StyleSheet`,
  `--lumo-*`, `--aura-*`, `--vaadin-*`) in a 1.x project.
- `var(--primary-color)` or any CSS custom property under Halo/Hover.
- A guessed style name — confirm a rule for it in the active theme's compiled CSS.
- `jmix.ui.theme-config` listing only the custom theme when users must still switch to
  a built-in one.
- A custom theme without `themes 'io.jmix.ui:jmix-ui-themes'` (nothing compiles it).
- Editing `build/themes` or the generated `addons` file.
- Inline `css` / `HtmlAttributes` for a look repeated across components — one class in
  the project theme instead.
- Claiming styling works from a green compile, `clean test`, or `@UiTest`.
