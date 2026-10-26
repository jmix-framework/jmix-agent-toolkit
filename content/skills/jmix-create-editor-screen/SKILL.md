---
name: jmix-create-editor-screen
description: Create a Jmix 1.x Classic UI entity editor - StandardEditor controller, XML descriptor with instance container, form, editActions and windowCommitAndClose/windowClose actions, messages and screen policy.
---

# Create Editor Screen

Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui`, Vaadin 8). Use this skill when creating
the create/edit screen for one entity. It is NOT Flow UI: `StandardDetailView`,
`@ViewController`, `@ViewComponent`, `<formLayout>`, `detail_saveClose`, `itemsQuery`,
`integerField`/`datePicker` do not exist in a Classic UI project.

The Studio 1.4.4 "Entity editor" template is the canon; the skeleton below is what it generates.

## Three defects that compile and open clean

1. **`<data readOnly="true">` in an editor saves NOTHING, silently.** It creates a no-op
   `DataContext`: the screen opens, the user edits, OK closes the screen with a SUCCESS result,
   and the database is unchanged. Browse screens use `readOnly="true"`; editors must use a plain
   `<data>`. Do not copy the `<data>` line from a browse descriptor.
2. **An enum attribute is NEVER `entityComboBox`.** `entityComboBox`/`entityPicker` are for
   entity references; binding one to an enum throws `IllegalStateException: Range is enumeration`
   when the screen opens. Use `<comboBox property="grade"/>` - options come from the enum.
3. **A missing message key shows the raw key** (`customerEdit.caption`) instead of failing. Add
   every key and look at the result.

## Read-only open mode vs read-only descriptor

Read-only OPEN MODE is chosen by the BROWSE screen: the `view` list action instead of `edit`
calls `setReadOnly(true)` on the editor, which makes data-bound fields non-editable and disables
every window action except `windowClose` (and `enableEditing`) at runtime. The editor descriptor stays a normal writable descriptor with
`windowCommitAndClose` and editable fields; new entities still open writable via `create`.

A descriptor with every field `editable="false"` and no commit action is always read-only and
cannot create or save anything. Mark a single field `editable="false"` only when it is read-only
in domain terms (audit fields, a generated number).

## Steps

1. Create the controller in `screen/<entityname>/`.
2. Extend `StandardEditor<Entity>` (`io.jmix.ui.screen.*`).
3. Add `@UiController("<Entity>.edit")`. `create`/`edit`/`view` actions and entity pickers'
   `entity_open` find the editor by this id; `@PrimaryEditorScreen(Entity.class)` overrides it.
4. Add `@UiDescriptor("<entity>-edit.xml")` (resolved in the controller's package).
5. Add `@EditedEntityContainer("<entity>Dc")`.
6. Create the XML: `<data>` (NOT read-only) with an `<instance>` container and an empty
   `<loader/>`, `dataLoadCoordinator`, the window actions, `<form>` with typed fields, and the
   `editActions` hbox with buttons for the actions.
7. Configure every reference field with a working option source (see Reference fields).
8. Use `InitEntityEvent` for UI-only defaults. A required persistent default belongs to the
   entity (field initializer, `@PostConstruct`, or an entity listener) - tests and services save
   through `DataManager` and never run the screen. See `jmix-create-entity`.
9. Add message keys for the caption and field captions (entity attribute messages are used for
   bound fields automatically). See `jmix-add-i18n-keys`.
10. Grant `@ScreenPolicy(screenIds = "<Entity>.edit")` on a method of a `@ResourceRole`
    interface (`io.jmix.securityui.role.annotation.ScreenPolicy`; no `value()` member). No
    `@MenuPolicy` for an editor that is not in the menu. See `jmix-create-resource-role`.
11. Before finishing, compare every field component against the Java property type.

## Controller Template

```java
package com.company.app.screen.customer;

import com.company.app.entity.Customer;
import io.jmix.ui.screen.*;

@UiController("Customer.edit")
@UiDescriptor("customer-edit.xml")
@EditedEntityContainer("customerDc")
public class CustomerEdit extends StandardEditor<Customer> {
}
```

`@Route(value = "customers/edit", parentPrefix = "customers")` (`io.jmix.ui.navigation.Route`) is
optional, as in the project template's `UserEdit`.

## XML Skeleton (Studio "Entity editor")

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<window xmlns="http://jmix.io/schema/ui/window"
        caption="msg://customerEdit.caption"
        focusComponent="form">
    <data>
        <instance id="customerDc"
                  class="com.company.app.entity.Customer">
            <fetchPlan extends="_base"/>
            <loader/>
        </instance>
    </data>
    <facets>
        <dataLoadCoordinator auto="true"/>
    </facets>
    <actions>
        <action id="windowCommitAndClose"
                caption="msg:///actions.Ok"
                icon="EDITOR_OK"
                primary="true"
                shortcut="${COMMIT_SHORTCUT}"/>
        <action id="windowClose"
                caption="msg:///actions.Close"
                icon="EDITOR_CANCEL"/>
    </actions>
    <dialogMode height="600"
                width="800"/>
    <layout spacing="true" expand="editActions">
        <form id="form" dataContainer="customerDc">
            <column width="350px">
                <textField id="nameField" property="name"/>
                <textField id="emailField" property="email"/>
                <comboBox id="gradeField" property="grade"/>
                <checkBox id="activeField" property="active"/>
                <textField id="creditLimitField" property="creditLimit"/>
                <textField id="visitsField" property="visits"/>
                <dateField id="birthDateField" property="birthDate"/>
                <textArea id="notesField" property="notes" rows="5"/>
            </column>
        </form>
        <hbox id="editActions" spacing="true">
            <button id="commitAndCloseBtn" action="windowCommitAndClose"/>
            <button id="closeBtn" action="windowClose"/>
        </hbox>
    </layout>
</window>
```

- The action ids are fixed (`StandardEditor.WINDOW_COMMIT_AND_CLOSE`, `WINDOW_COMMIT`,
  `WINDOW_CLOSE`): `windowCommitAndClose`, `windowCommit`, `windowClose`. `StandardEditor` adds
  any of them that the descriptor omits, but only a button makes them reachable - an editor
  without `editActions` buttons cannot be saved by a user. For a separate "Save" button add
  `<action id="windowCommit" caption="msg:///actions.Save" icon="SAVE"/>` and
  `<button id="commitBtn" action="windowCommit"/>`.
- `<dialogMode>` only sets geometry when the editor is opened as a dialog; actions open editors
  in the current tab by default. For a small editor that must always be a dialog use
  `<dialogMode height="AUTO" width="AUTO" modal="true" forceDialog="true"/>`.
- With more than about ten fields Studio wraps the form in `<scrollBox id="scrollBox">` and sets
  `expand="scrollBox"`.

## Field component mapping

What the Studio form snippet generates, by property type:

| Property type | Component |
| --- | --- |
| `String` | `textField` |
| `String` with `@Lob` | `textArea rows="5"` |
| `Integer`, `Long`, `BigDecimal`, `Double` | `textField` (converts by the property's datatype) |
| `Boolean` | `checkBox` (capital B) |
| `LocalDate`, `LocalDateTime`, `OffsetDateTime`, `java.util.Date` | `dateField` |
| `LocalTime`, `OffsetTime` | `timeField` |
| Jmix enum | `comboBox` |
| `UUID` | `maskedField mask="hhhhhhhh-hhhh-hhhh-hhhh-hhhhhhhhhhhh"` |
| `FileRef` | `fileStorageUpload` |
| `byte[]` | `fileUpload` |
| Entity reference | `entityPicker` with lookup/clear actions, or `entityComboBox` |

Unlike Flow UI, a `textField` bound to a numeric property is correct in Classic UI: it parses and
formats with the property datatype and rejects non-numeric input on validation. Do not invent
`integerField`/`bigDecimalField` elements - they do not exist in `layout.xsd`.

A `checkBox` bound to a `@NotNull Boolean` accepts `false`: Classic UI treats only `null` as empty,
so no `required="false"` workaround is needed.

Do not expose technical fields (`id`, `version`). Hide a required field only when it is initialized
elsewhere: a field with `visible="false"` or `editable="false"` skips its required check and
validators, so the screen-level check passes and the save fails later on the entity constraint.

## Reference fields

- **`entityPicker` with `entity_lookup` and `entity_clear`** - Studio's default. The lookup action
  opens `<Entity>.lookup`, or `<Entity>.browse` when no `.lookup` exists; that screen must have
  `@LookupComponent`. Use the literal action types:

  ```xml
  <entityPicker id="parentField" property="parent">
      <actions>
          <action id="entityLookup" type="entity_lookup"/>
          <action id="entityClear" type="entity_clear"/>
      </actions>
  </entityPicker>
  ```

  `entity_open` (open the referenced entity's editor) is also available.

- **`entityComboBox` with `optionsContainer`** - for small candidate sets. Declare a top-level
  collection loaded by the same `dataLoadCoordinator`:

  ```xml
  <data>
      <instance id="salesOrderDc" class="com.company.app.entity.SalesOrder">
          <fetchPlan extends="_base">
              <property name="customer" fetchPlan="_base"/>
          </fetchPlan>
          <loader/>
      </instance>
      <collection id="customersDc" class="com.company.app.entity.Customer">
          <fetchPlan extends="_base"/>
          <loader id="customersDl">
              <query><![CDATA[select e from Customer e order by e.name]]></query>
          </loader>
      </collection>
  </data>
  ...
  <entityComboBox id="customerField" property="customer" optionsContainer="customersDc"/>
  ```

  Classic UI has no `itemsQuery`/`itemsContainer`; the attribute is `optionsContainer`. The JPQL
  uses the entity name, not the table name.

Include the reference in the edited entity's fetch plan (`<property name="customer" .../>`),
otherwise the field shows nothing for saved records (see `jmix-configure-fetch-plan`).

## To-many collections on the editor

Nest a property-bound collection inside the `<instance>` and bind a table to it:

```xml
<instance id="salesOrderDc" class="com.company.app.entity.SalesOrder">
    <fetchPlan extends="_base">
        <property name="lines" fetchPlan="_base"/>
    </fetchPlan>
    <loader/>
    <collection id="linesDc" property="lines"/>
</instance>
```

The nested container takes `property` only: no `class`, no loader, no query (a `class` there is
ignored, so leave it out). The parent fetch plan must include the property, or the table is empty.
For editing children see `jmix-create-composition-editor`.

## Controller events

Inject components and beans with `@Autowired` (field name = component id); handle events with
`@Subscribe`. Verified signatures:

```java
@Autowired
private MessageBundle messageBundle;   // io.jmix.ui.screen.MessageBundle: screen's message group

@Subscribe
public void onInitEntity(InitEntityEvent<SalesOrder> event) {   // only for NEW entities
    event.getEntity().setDate(LocalDate.now());
}

@Subscribe
public void onValidation(ValidationEvent event) {              // cross-field validation
    if (getEditedEntity().getLines() == null || getEditedEntity().getLines().isEmpty()) {
        event.getErrors().add(messageBundle.getMessage("noLines"));
    }
}
```

Errors added in `ValidationEvent` block the commit (`closeWithCommit()` returns `FAIL`) and are
shown to the user. Other useful events: `AfterShowEvent`, `BeforeCommitChangesEvent`,
`AfterCommitChangesEvent`, and `@Subscribe(target = Target.DATA_CONTEXT)` for
`DataContext.PostCommitEvent` (see the project template's `UserEdit`).

## Asking for confirmation before saving

`ValidationEvent` can only reject. To suspend a save and continue it after a question, use
`BeforeCommitChangesEvent.preventCommit()` and `resume()`:

```java
@Autowired
private Dialogs dialogs;   // io.jmix.ui.Dialogs

@Subscribe
public void onBeforeCommitChanges(BeforeCommitChangesEvent event) {
    if (!needsConfirmation()) {
        return;
    }
    event.preventCommit();
    dialogs.createOptionDialog()
            .withCaption(messageBundle.getMessage("confirmLimit.caption"))
            .withMessage(messageBundle.getMessage("confirmLimit.message"))
            .withActions(
                    new DialogAction(DialogAction.Type.YES)   // io.jmix.ui.action.DialogAction
                            .withHandler(e -> event.resume()),
                    new DialogAction(DialogAction.Type.NO))
            .show();
}
```

Without `preventCommit()` the commit runs regardless of what the dialog shows.

## Styling

Styling fields and layouts (`stylename`, theme variables, SCSS) is covered by `jmix-style-ui`.

## Proving it

The descriptor is parsed only when the screen opens - not at context start - so a green build and
context-load test prove nothing about it. Open the editor in a `@UiTest` (see `jmix-create-test`),
set field values, call `closeWithCommit()` and assert both its status and what is in the database:
that is the only check that catches defect 1 above.

## Forbidden

- `<data readOnly="true">` in an editor.
- `entityComboBox` / `entityPicker` bound to an enum attribute.
- Flow UI elements and actions (`formLayout`, `detail_saveClose`, `itemsQuery`, `integerField`, `datePicker`).
- An editor without buttons for `windowCommitAndClose` (or `windowCommit`) and `windowClose`.
- Screen id other than `<Entity>.edit` without `@PrimaryEditorScreen`.
- Reference fields without lookup actions or `optionsContainer`, or missing from the fetch plan.
- `@Table` names in JPQL.
- Hardcoded captions.
- Hiding required fields without setting defaults elsewhere.
- Missing `@ScreenPolicy` for the editor.
