---
name: jmix-add-i18n-keys
description: Add complete Jmix 1.x message keys for entities, enums, Classic UI screens, actions, menu items and validation text, and configure official Jmix framework translations for non-English applications.
---

# Add I18n Keys

Stack: Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui`, XML screen descriptors).

Use this skill whenever adding user-visible text, entities, enum values, screens,
validation messages, or a non-English application locale.

## Bundle layout (1.4 project template)

The application has ONE message bundle: `messages_<locale>.properties` in the base
package, e.g. `src/main/resources/com/company/app/messages_en.properties`. There are no
per-screen bundle files. Every key carries its message group as a prefix before `/`:

```properties
localeDisplayName.en=English

com.company.app.entity/Customer=Customer
com.company.app.entity/Customer.name=Name

com.company.app.entity/OrderStatus=Order status
com.company.app.entity/OrderStatus.NEW=New

com.company.app.screen.customer/customerBrowse.caption=Customers
com.company.app.screen.customer/customerEdit.caption=Customer editor
com.company.app.screen.customer/createOrderBtn.caption=Create order

com.company.app/menu.sales=Sales
```

- Entity: `<package>/<Class>`; attribute: `<package>/<Class>.<attribute>`.
- Enum: `<package>/<Enum>` for the enum name, `<package>/<Enum>.<CONSTANT>` for each
  constant (`Messages.getMessage(Enum)` reads `<Enum>.<CONSTANT>` in the enum's package
  group).
- Screen keys use the screen's package as the group. Studio names new screen keys
  after the decapitalized controller (`customerBrowse.caption`, `customerEdit.caption`),
  while the generated User screens use `UserBrowse.caption` / `UserEdit.caption`. Both
  work; the reference must match the key exactly.
- A key with no group (`localeDisplayName.en`, `probeKey`) is in the main group.
- More bundles: `@MessageSourceBasenames` on the application class.

## Steps

1. For a non-English application, add the official Jmix translation dependency for the target language before writing framework or add-on message overrides, and list the locale in the application's `jmix.core.available-locales`.
2. Find all `messages_<locale>.properties` files of the application (one per locale).
3. Add the same application-owned keys to every locale file.
4. Use entity keys for entity captions and attributes.
5. Use enum keys for the enum and every enum constant.
6. Use screen-group keys for captions, button text, labels, and dialog text.
7. Use `msg://` in XML descriptors and `menu.xml`.
8. Use `MessageBundle` in screen controllers and `Messages` in services/beans.
9. Check every `msg://` reference against the bundle key exactly; key lookup is case-sensitive.
10. Use full `msg://<message-group>/<key>` references when the key belongs to another message group.

## Official framework translations

Application bundles translate application-owned text only. For a non-English
application, add the official translation module to `build.gradle`:

```groovy
implementation 'io.jmix.translations:jmix-translations-<locale>'
```

The Jmix 1.4.4 BOM manages these locales: `ckb` (Central Kurdish), `de` (German),
`el` (Greek), `fr` (French), `nl` (Dutch), `ro` (Romanian), `ru` (Russian), and
`zh-cn` (Simplified Chinese). For another Jmix 1.x version, read the list from that
BOM (`jmix-bom-<version>.pom`, artifacts `jmix-translations-*`); the 2.x/3.x lists are
longer and do not apply. Do not add a version: the BOM resolves it.

Add this dependency before creating files such as
`src/main/resources/io/jmix/ui/messages_<lang>.properties` or message bundles inside
add-on packages. Official translations contain most Jmix framework and supported add-on
messages, but some may be missing. Add local overrides only for missing messages or
intentional wording changes; do not copy complete bundles that can become outdated
after a Jmix upgrade.

Run the application in the target locale and inspect framework-owned screens, filter
dialogs, and add-on screens. Also inspect a Boolean value rendered by Jmix: English
`True` and `False` captions (`trueString` / `falseString` in `io.jmix.core`) are a
visible sign that the framework translation is not active.

## Available locales

The login screen offers the locales in `jmix.core.available-locales` (default: `en`
only). Set the full list in the application's `application.properties`:

```properties
jmix.core.available-locales = en,ru
```

Each locale's display name in the login screen's locale selector is the
`localeDisplayName.<locale>` key of the main group in that locale's bundle
(`localeDisplayName.ru=Русский` in `messages_ru.properties`); without it Jmix falls back
to `Locale.getDisplayName()`.

## XML Usage

A Jmix 1.x message reference has three forms:

- Brief: `msg://<key>` — resolved in the descriptor's own message group.
- Full: `msg://<message-group>/<key>`.
- Main group: `msg:///<key>` (triple slash) — a key without a group, e.g. the
  framework's `msg:///actions.Ok` used in generated editors.

The descriptor's group is the package of the directory holding the XML
(`com/company/app/screen/customer/customer-browse.xml` →
`com.company.app.screen.customer`), unless the `<window>`/`<fragment>` root sets
`messagesGroup="..."`.

`mainMsg://` is a CUBA form. Jmix 1.4 `MessageTools.loadString` does not resolve it:
the literal `mainMsg://key` is rendered. Use `msg:///key`.

Brief references are fine for keys stored in the descriptor's group:

```xml
<window xmlns="http://jmix.io/schema/ui/window"
        caption="msg://customerBrowse.caption">
    ...
    <button id="createOrderBtn" caption="msg://createOrderBtn.caption"/>
</window>
```

Use a full reference for a key in another group: entity captions, menu captions,
shared keys. `menu.xml` has no descriptor group, so its references are always full:

```xml
<menu id="sales" caption="msg://com.company.app/menu.sales">
    <item screen="Customer.browse"
          caption="msg://com.company.app.screen.customer/customerBrowse.caption"/>
</menu>
<label value="msg://com.company.app.entity/Customer.orders"/>
```

Classic UI components use `caption` (and `value` for `label`), not Flow UI's `text`/`title`.

For Bean Validation messages, put the full reference inside braces:

```java
@NotNull(message = "{msg://com.company.app.entity/Customer.email.required}")
private String email;
```

## Java Usage In Screens

```java
import io.jmix.ui.screen.MessageBundle;

@Autowired
private MessageBundle messageBundle;   // the screen's message group

String text = messageBundle.getMessage("createOrderBtn.caption");
String formatted = messageBundle.formatMessage("ordersCount", count);   // String.format: %s, %d
```

Inject `MessageBundle` only as a field of a screen or fragment controller: the screen
injector sets its group. Obtained any other way it throws `messageGroup is not set`.

In beans and services inject `io.jmix.core.Messages`:
`messages.getMessage("com.company.app.screen.customer", "createOrderBtn.caption")`,
`messages.getMessage(getClass(), "key")` (group = the class's package),
`messages.getMessage(OrderStatus.NEW)` for an enum constant.

For entity/attribute captions inject `io.jmix.core.MessageTools` and `Metadata`:
`messageTools.getEntityCaption(metadata.getClass(Customer.class))` and
`messageTools.getPropertyCaption(metadata.getClass(Customer.class), "name")`.

A missing key never throws: `Messages` returns the bare key (without the group) and the
screen shows it. Only a reference audit or a look at the rendered screen catches it.

## Exact Reference Audit

Before finishing, perform both audit passes below.

### 1. Verify references

Search changed XML (descriptors and `menu.xml`) and Java for message references and
verify each key exists in the right group with identical casing:

```bash
grep -rhoE 'msg://[^"<> ]*' src/main/resources --include='*.xml' | sort -u
grep -rn 'mainMsg://' src/main      # must be empty
```

For a brief `msg://key`, the properties key is `<descriptor package>/key`; for
`msg:///key` it is `key` with no group. Do not rely on similar casing such as
`CustomerBrowse.caption` vs `customerBrowse.caption`.

### 2. Verify translated values

Every locale bundle other than the one whose language the keys are authored in must be
reviewed for leftover template values — including in an `en,<other>` application,
where the second bundle may be a copy of the English one and every key in it resolves.

Read each such `messages_<locale>.properties` file complete, not only the lines
changed during the task. Check seed keys for the login screen, main screen, menu, and
user entity as well as newly added keys.

For a locale that normally uses non-Latin text, use this search to find likely
English values left from the template:

```bash
rg -n '^[^#=]+=[\x00-\x7F]+$' \
  -g 'messages_<locale>.properties' src/main/resources
```

Review every match; this is a heuristic, not proof of an error. Product names, URLs,
abbreviations, numbers, and intentionally untranslated technical terms can be valid.
Values such as `...screen.login/loginButton = Submit` or `.../User=User` usually require
translation in a non-English-only application.

When the task adds keys to a bundle that is still an untouched template, pick one of
two outcomes and say which — translating the whole bundle, or translating only the
new keys and recording the rest as a known gap. Both are defensible. Translating the
new keys and silently leaving the seed keys is not.

## Forbidden

- Hardcoded user-visible text in XML or Java controllers.
- Adding a key to only one locale file.
- `msg://` keys that differ from properties keys only by case.
- Brief `msg://key` references to keys stored in another message group (and any brief reference in `menu.xml`).
- `mainMsg://` references.
- Missing enum or enum-constant messages.
- `${0}` / `{0}` placeholders in `formatMessage`; it uses `String.format` (`%s`, `%d`).
- Copies of framework or add-on message bundles created before checking for an
  official `jmix-translations-<lang>` artifact.
- English template values left without explicit review in any locale bundle other
  than the one the keys are authored in.
