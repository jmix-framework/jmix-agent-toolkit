---
name: jmix-add-dialog-editor-flow
description: Open a Jmix Classic UI entity editor or lookup screen as a dialog from a button/action (ScreenBuilders, OpenMode.DIALOG, @DialogMode), react to its close outcome, and refresh related loaders after commit.
---

# Add Dialog Editor Flow

Stack: Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui`, Vaadin 8).

Use this skill when a button or action should create or edit an entity in a modal
editor screen, pick entities in a lookup dialog, or collect a small scalar value
through a Jmix input dialog. For parent-owned children edited inside the parent's own
editor via a property-bound `<collection property=...>` container (no query loader),
use `jmix-create-composition-editor` instead.

This is Classic UI. There is no `DialogWindows`, no `@ViewComponent`, no `DataGrid`
`ClickEvent<JmixButton>` here — those are Flow UI (Jmix 2/3). The 1.x equivalents are
`ScreenBuilders`, `@Autowired` component injection, and `Button.ClickEvent`.

## Steps

1. Inject `ScreenBuilders` with `@Autowired`. Inject components, containers and
   loaders with `@Autowired` too (Studio 1.4 generates `@Autowired`; `@Inject` also
   works).
2. On click, get the selected master entity if needed
   (`table.getSingleSelected()`).
3. Open `screenBuilders.editor(Entity.class, this)` with `.newEntity()` or
   `.editEntity(entity)`, `.withInitializer(...)` for parent/default fields and
   `.withOpenMode(OpenMode.DIALOG)`.
4. React to the close: either `.withScreenClass(EditorClass.class)` and then
   `.withAfterCloseListener(...)`, or `.build()` + `screen.addAfterCloseListener(...)`
   + `screen.show()` (see the pitfall below). Reload every affected loader only when
   the event `closedWith(StandardOutcome.COMMIT)`.
5. Make sure the editor exists and roles have its `@ScreenPolicy` (see
   `jmix-create-editor-screen` and `jmix-create-resource-role`).
6. Cover the flow with a `@UiTest` that clicks the button and asserts the dialog
   screen (see **Verify**).

## Create Child Entity From Selected Master

```java
import io.jmix.ui.ScreenBuilders;
import io.jmix.ui.component.Button;
import io.jmix.ui.component.Table;
import io.jmix.ui.model.CollectionLoader;
import io.jmix.ui.screen.*;
import org.springframework.beans.factory.annotation.Autowired;

@Autowired
private ScreenBuilders screenBuilders;
@Autowired
private Table<Customer> customersTable;
@Autowired
private CollectionLoader<Customer> customersDl;
@Autowired
private CollectionLoader<Contact> contactsDl;

@Subscribe("createContactBtn")
public void onCreateContactBtnClick(Button.ClickEvent event) {
    Customer customer = customersTable.getSingleSelected();
    if (customer == null) {
        return;
    }
    screenBuilders.editor(Contact.class, this)
            .withScreenClass(ContactEdit.class)      // unlocks withAfterCloseListener
            .newEntity()
            .withInitializer(contact -> contact.setCustomer(customer))
            .withOpenMode(OpenMode.DIALOG)
            .withAfterCloseListener(closeEvent -> {
                if (closeEvent.closedWith(StandardOutcome.COMMIT)) {
                    contactsDl.load();
                    customersDl.load();
                }
            })
            .show();
}
```

### `withAfterCloseListener` exists only after `withScreenClass`

`EditorBuilder` (what `editor(...)` returns) has NO `withAfterCloseListener` /
`withAfterShowListener` — they live on `EditorClassBuilder`, returned by
`withScreenClass(...)`. The same split exists for `LookupBuilder` /
`LookupClassBuilder` and `ScreenBuilder` / `ScreenClassBuilder`. Without a screen class
(the editor is resolved by entity, or by `withScreenId`), build the screen and add the
listener on it:

```java
Screen editor = screenBuilders.editor(Contact.class, this)
        .editEntity(contact)
        .withOpenMode(OpenMode.DIALOG)
        .build();
editor.addAfterCloseListener(closeEvent -> {
    if (closeEvent.closedWith(StandardOutcome.COMMIT)) {
        contactsDl.load();
    }
});
editor.show();
```

The outcomes are `StandardOutcome.COMMIT` (OK / `closeWithCommit()`), `CLOSE`,
`DISCARD`, `SELECT` (lookup). There is no `SAVE` in 1.x.

`show()` opens the screen; there is no `open()` on these builders.

### When the opener does not need a reload

`screenBuilders.editor(table)` (or `.withContainer(dc)` / `.withListComponent(table)`)
adds or replaces the committed entity in that container itself, and so do the standard
`create` / `edit` table actions. Reload a loader only for data the editor does NOT
write back to: another table, a count, a derived field.

## Standard actions in the descriptor

Declare `create` / `edit` on the table and set the open mode through nested
`<properties>` — `openMode` is a bean property of the action, not an XML attribute:

```xml
<table id="customersTable" width="100%" dataContainer="customersDc">
    <actions>
        <action id="create" type="create">
            <properties>
                <property name="openMode" value="DIALOG"/>
            </properties>
        </action>
        <action id="edit" type="edit">
            <properties>
                <property name="openMode" value="DIALOG"/>
            </properties>
        </action>
        <action id="remove" type="remove"/>
    </actions>
    ...
    <buttonsPanel id="customersButtonsPanel" alwaysVisible="true">
        <button id="createBtn" action="customersTable.create"/>
        <button id="editBtn" action="customersTable.edit"/>
        <button id="removeBtn" action="customersTable.remove"/>
    </buttonsPanel>
</table>
```

The same works for `entity_lookup` on an `entityPicker` (opens the lookup screen in a
dialog). Hook into a standard action from the controller with `@Install` on
`<tableId>.<actionId>`; `CreateAction` / `EditAction` expose `afterCommitHandler`,
`afterCloseHandler`, `initializer` (create only), `screenConfigurer`, `transformation`:

```java
@Install(to = "customersTable.create", subject = "afterCommitHandler")
private void customersTableCreateAfterCommitHandler(Customer customer) {
    contactsDl.load();
}
```

## `@DialogMode` and `<dialogMode>`

```java
@UiController("Contact.edit")
@UiDescriptor("contact-edit.xml")
@EditedEntityContainer("contactDc")
@DialogMode(width = "500px", height = "AUTO", forceDialog = true)
public class ContactEdit extends StandardEditor<Contact> {
}
```

- `width` / `height` / `modal` / `closeable` / `resizable` / `closeOnClickOutside` /
  `windowMode` apply ONLY when the screen is opened as `OpenMode.DIALOG`. The
  `<dialogMode height="600" width="800"/>` that Studio puts in every generated
  descriptor is the same thing: it does NOT make the screen a dialog.
- `forceDialog = true` (annotation, or `forceDialog="true"` on `<dialogMode>`) opens the
  screen as a dialog whatever open mode the caller asked for, including menu and
  standard actions; the annotation's `width`/`height` still apply.
- Any non-dialog screen opened while a modal dialog is already open is turned into a
  dialog automatically, and then it gets the theme's forced-dialog size
  (`jmix.ui.WebWindowManager.forciblyDialog.width/height`), not your `@DialogMode`
  size.

## Lookup in a dialog

```java
screenBuilders.lookup(Customer.class, this)
        .withScreenClass(CustomerBrowse.class)
        .withOpenMode(OpenMode.DIALOG)
        .withSelectHandler(customers -> {
            contact.setCustomer(customers.iterator().next());
            dataManager.save(contact);
            contactsDl.load();
        })
        .show();
```

The lookup screen must be a `StandardLookup` with `@LookupComponent` and the
`lookupActions` box from the Studio template (see `jmix-create-browse-screen`). Keep
the save in a service when it carries business rules (`jmix-create-service`).

## Related Table Loader

Prefer binding the child loader to the selected master through a container parameter:

```xml
<collection id="contactsDc" class="com.company.app.entity.Contact">
    <fetchPlan extends="_base"/>
    <loader id="contactsDl">
        <query>
            <![CDATA[select e from Contact e where e.customer = :container_customersDc order by e.name]]>
        </query>
    </loader>
</collection>
...
<facets>
    <dataLoadCoordinator auto="true"/>
</facets>
```

With `auto="true"` the coordinator reloads `contactsDl` on every `customersDc` item
change and passes the current item (or `null` — no rows) as the parameter. Write
`:container_customersDc`, never `:container_customersDc.selected` or `.id`.

A MANUAL parameter (anything not `:container_*` / `:component_*`, e.g. `:customer`)
gets no trigger from the auto coordinator in 1.4: such a loader is simply never
loaded, with no error. Load it yourself after `setParameter`:

```java
Customer customer = customersTable.getSingleSelected();
if (customer == null) {
    contactsDc.getMutableItems().clear();
    return;
}
contactsDl.setParameter("customer", customer);
contactsDl.load();
```

Compare an entity-valued property to an entity parameter (`e.customer = :customer`),
or an id to an id (`e.customer.id = :customerId`). Never call `load()` after removing a
parameter the query still needs.

Selection handler, if you do it by hand:

```java
@Subscribe("customersTable")
public void onCustomersTableSelection(Table.SelectionEvent<Customer> event) { ... }
```

## Migrating from service call to entity create

To migrate a button from "collect a value, call a service" to "create an entity
through its editor", REMOVE the input dialog and open the editor DIRECTLY. Do NOT chain
an `InputDialog` before the editor: a UI test that clicks the button expects the
editor screen as the top dialog, and casting an `InputDialog` to it throws
`ClassCastException`. The editor collects the attributes; the entity is created on
commit; a side effect (e.g. an `EntityChangedEvent` listener) performs any derived
update. "Open the X editor from the button" means literally no `InputDialog`, no
`MessageDialog`, and no service call before the dialog opens.

## Scalar Input Dialog

For a button that collects a simple value and then calls a service, use the Jmix input
dialog, not a hand-built window:

```java
import io.jmix.ui.Dialogs;
import io.jmix.ui.app.inputdialog.DialogActions;
import io.jmix.ui.app.inputdialog.DialogOutcome;
import io.jmix.ui.app.inputdialog.InputParameter;

@Autowired
private Dialogs dialogs;

@Subscribe("renameBtn")
public void onRenameBtnClick(Button.ClickEvent event) {
    Customer customer = customersTable.getSingleSelected();
    if (customer == null) {
        return;
    }
    dialogs.createInputDialog(this)
            .withCaption(messageBundle.getMessage("renameDialog.caption"))
            .withParameters(
                    InputParameter.stringParameter("name")
                            .withCaption(messageBundle.getMessage("renameDialog.name"))
                            .withRequired(true)
                            .withDefaultValue(customer.getName()))
            .withActions(DialogActions.OK_CANCEL)
            .withCloseListener(closeEvent -> {
                if (closeEvent.closedWith(DialogOutcome.OK)) {
                    String name = closeEvent.getValue("name");
                    customerService.rename(customer, name);   // your service bean
                    customersDl.load();
                }
            })
            .show();
}
```

1.x names: `withCaption` (not `withHeader`), `InputParameter.withCaption` (not
`withLabel`), `show()` (not `open()`). For numbers use `InputParameter.intParameter`,
`longParameter`, `doubleParameter`, `bigDecimalParameter` — not `stringParameter` +
`Integer.parseInt`. Keep the service call in a service; the screen only collects
input, calls it and reloads loaders.

## `@Subscribe` handler signature

A button click handler takes `Button.ClickEvent`:

```java
@Subscribe("createContactBtn")
public void onCreateContactBtnClick(Button.ClickEvent event) { ... }
```

An `Action` handler takes `Action.ActionPerformedEvent`
(`@Subscribe("customersTable.myAction")`). A handler whose parameter type the target
cannot deliver fails when the screen is opened
(`DevelopmentException: Target ... does not support event type ...`) — fix the
parameter type, not the dialog.

## Whose data context does the dialog use

Whether the editor's OK writes to the database at once or merges into the opener
depends on how it was opened. The default is the immediate write, and `@Composition` on
the attribute is what switches it off:

| opened with | parent context | what OK does |
| --- | --- | --- |
| `.withParentDataContext(ctx)` | yes | merges into the parent; reaches the DB when the parent commits |
| `.withContainer(c)` where `c` is a property-bound `<collection property="x"/>` and `x` has `@Composition` (also standard `create`/`edit` on a table bound to such a container) | yes | same |
| `.withField(f)` whose value source is a `@Composition` reference | yes | same |
| a standalone container with a loader — the usual browse screen, including its standard `create` / `edit` | **no** | commits to the DB; the committed entity is then merged into the opener's `DataContext` |
| a property-bound container / field whose attribute is a plain association (**no** `@Composition`) | **no** | same as above |
| plain `screenBuilders.editor(...)` with none of the above | **no** | commits to the DB; a later Cancel on the opener does not undo it |

- Independent on purpose: open without `withContainer` / `withField` /
  `withParentDataContext`, and reload the opener's loader after `COMMIT`.
- Atomic with the parent: pass `.withParentDataContext(getScreenData().getDataContext())`
  explicitly.

When a parent context is set up, both screens must take part:

- The editor has no `<data>` → `DevelopmentException: No DataContext in screen '<id>'.
  Composition editing is impossible.`
- The opener has `<data readOnly="true">` (a `NoopDataContext`) →
  `IllegalArgumentException: Unsupported DataContext type ... Parent DataContext must
  implement DataContextInternal`. Studio's browse template uses `readOnly="true"`;
  drop it on a screen that is a parent context.

## Verify

A `clean test` that only starts the context proves nothing about screens: in 1.4.4 a
descriptor is parsed only when the screen is created. Open the flow in a `@UiTest`
(`testImplementation 'io.jmix.ui:jmix-ui-test-assist'`, see `jmix-create-test`):

```java
@UiTest(authenticatedUser = "admin")
@SpringBootTest(classes = {DemoApplication.class, UiTestAssistConfiguration.class})
class ContactDialogTest {

    @Test
    void createContactOpensDialog(Screens screens) {
        CustomerBrowse browse = screens.create(CustomerBrowse.class);
        browse.show();
        // select a customer in customersTable, then:
        ((Button) browse.getWindow().getComponentNN("createContactBtn")).click();

        Screen top = screens.getOpenedScreens().getDialogScreens().stream()
                .reduce((a, b) -> b).orElseThrow();
        assertTrue(top instanceof ContactEdit);
        assertTrue(top.getWindow() instanceof DialogWindow);

        ((ContactEdit) top).getEditedEntity().setName("John");
        ((ContactEdit) top).closeWithCommit();    // fires the after-close listener with COMMIT
        // assert the reloaded container
    }
}
```

UI-scoped beans (`Fragments`, `Dialogs`, `Notifications`, `ScreenBuilders`) cannot be
`@Autowired` into the test class (`Found no valid com.vaadin.spring.internal.UIID
instance!`); take `Screens` as a test-method parameter and get others from the
`ApplicationContext` inside the test method.

## Forbidden

- Flow UI APIs (`DialogWindows`, `@ViewComponent`, `StandardOutcome.SAVE`,
  `ClickEvent<JmixButton>`) in a 1.x project.
- `withAfterCloseListener` on the untyped `EditorBuilder` / `LookupBuilder` — call
  `withScreenClass(...)` first, or use `build()` + `addAfterCloseListener`.
- `openMode` as an XML attribute of a table `<action>` — use nested `<properties>`.
- Relying on `<dialogMode width/height>` to make a screen open as a dialog — that needs
  `OpenMode.DIALOG` or `forceDialog`.
- A hand-built `Window`/Vaadin dialog for entity create/edit or scalar input.
- Direct service update when the domain requires creating an entity record.
- Chaining an `InputDialog`/`MessageDialog`/service call before opening the editor when
  the button should open the editor directly.
- Reloading loaders after close without checking `closedWith(StandardOutcome.COMMIT)`.
- Comparing entity-valued JPQL properties to UUID parameters.
- `.selected` / `.id` inside a `:container_*` JPQL parameter.
- A manual-parameter loader expected to load by itself under
  `<dataLoadCoordinator auto="true"/>` — it is silently never loaded.
- `stringParameter` + `Integer.parseInt` for a numeric input.
