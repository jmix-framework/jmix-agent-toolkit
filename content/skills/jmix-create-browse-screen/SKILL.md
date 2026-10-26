---
name: jmix-create-browse-screen
description: Create a Jmix 1.x Classic UI browse (lookup) screen - StandardLookup controller, XML descriptor with collection container, loader, table and buttonsPanel, menu item, messages and screen policy.
---

# Create Browse Screen

Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui`, Vaadin 8). Use this skill when creating
a top-level browse/lookup screen for an entity. It is NOT Flow UI: in 1.4 Flow UI is only a
preview, and its `StandardListView`, `@ViewController`, `@Route(layout = MainView.class)`,
`<view xmlns=".../flowui/view">` and `list_create` action types do not exist in a Classic UI
project. If you see them in an example, it is the wrong edition.

The Studio 1.4.4 "Entity browser" template is the canon: it generates exactly the controller and
descriptor shown below. Follow it unless the project already uses another compiled pattern.

## Steps

1. Create the Java controller in `screen/<entityname>/` (e.g. `com.company.app.screen.customer`).
2. Extend `StandardLookup<Entity>` (`io.jmix.ui.screen.*`).
3. Add `@UiController("<Entity>.browse")`. The id convention matters: create/edit actions find the
   editor as `<Entity>.edit`, entity pickers find the lookup screen as `<Entity>.lookup` first and
   then `<Entity>.browse`. `@PrimaryLookupScreen(Entity.class)` overrides the convention.
4. Add `@UiDescriptor("<entity>-browse.xml")`. A bare file name is resolved in the controller's
   package, so put the XML under `src/main/resources/<same/package/path>/`.
5. Add `@LookupComponent("<entities>Table")`. Without it the screen opens fine from the menu but
   throws `IllegalStateException: StandardLookup ... does not declare @LookupComponent` the
   moment it is opened as a lookup (entity picker, `ScreenBuilders.lookup`). Always add it.
6. Create the XML descriptor: `<data readOnly="true">` with a collection container and loader,
   `dataLoadCoordinator` facet, lookup actions, the table with its `<actions>`, `<columns>`,
   `<simplePagination/>` and `<buttonsPanel>`, and the hidden `lookupActions` hbox.
7. JPQL uses the entity name, not the table name (see below).
8. Render a visible button for every table action users must trigger.
9. Add a `menu.xml` item for screens that should appear in navigation.
10. Add message keys for the caption and every custom button caption (see `jmix-add-i18n-keys`).
11. Grant access in a `@ResourceRole` interface with `@ScreenPolicy(screenIds = "<Entity>.browse")`
    and `@MenuPolicy(menuIds = "<Entity>.browse")` (`io.jmix.securityui.role.annotation`), on a
    method, not on the controller. Neither annotation has a `value()`. The editor needs its own
    `@ScreenPolicy`. See `jmix-create-resource-role`.

## Controller Template

```java
package com.company.app.screen.customer;

import com.company.app.entity.Customer;
import io.jmix.ui.screen.*;

@UiController("Customer.browse")
@UiDescriptor("customer-browse.xml")
@LookupComponent("customersTable")
public class CustomerBrowse extends StandardLookup<Customer> {
}
```

`@Route("customers")` (`io.jmix.ui.navigation.Route`) is optional; add it only for a bookmarkable
URL. There is no `layout` attribute in Classic UI.

## XML Skeleton (Studio "Entity browser")

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<window xmlns="http://jmix.io/schema/ui/window"
        caption="msg://customerBrowse.caption"
        focusComponent="customersTable">
    <data readOnly="true">
        <collection id="customersDc"
                    class="com.company.app.entity.Customer">
            <fetchPlan extends="_base"/>
            <loader id="customersDl">
                <query>
                    <![CDATA[select e from Customer e order by e.name]]>
                </query>
            </loader>
        </collection>
    </data>
    <facets>
        <dataLoadCoordinator auto="true"/>
        <screenSettings id="settingsFacet" auto="true"/>
    </facets>
    <actions>
        <action id="lookupSelectAction"
                caption="msg:///actions.Select"
                icon="LOOKUP_OK"
                primary="true"
                shortcut="${COMMIT_SHORTCUT}"/>
        <action id="lookupCancelAction"
                caption="msg:///actions.Cancel"
                icon="LOOKUP_CANCEL"/>
    </actions>
    <dialogMode height="600"
                width="800"/>
    <layout expand="customersTable" spacing="true">
        <filter id="filter"
                dataLoader="customersDl">
            <properties include=".*"/>
        </filter>
        <groupTable id="customersTable"
                    width="100%"
                    dataContainer="customersDc">
            <actions>
                <action id="create" type="create"/>
                <action id="edit" type="edit"/>
                <action id="remove" type="remove"/>
            </actions>
            <columns>
                <column id="name"/>
                <column id="email"/>
                <column id="grade"/>
                <column id="active"/>
            </columns>
            <simplePagination/>
            <buttonsPanel id="buttonsPanel"
                          alwaysVisible="true">
                <button id="createBtn" action="customersTable.create"/>
                <button id="editBtn" action="customersTable.edit"/>
                <button id="removeBtn" action="customersTable.remove"/>
            </buttonsPanel>
        </groupTable>
        <hbox id="lookupActions" spacing="true" visible="false">
            <button action="lookupSelectAction"/>
            <button action="lookupCancelAction"/>
        </hbox>
    </layout>
</window>
```

Notes on the skeleton:

- `<data readOnly="true">` is right for a browse screen (no `DataContext`, nothing to save). Never
  copy it into an editor - see `jmix-create-editor-screen`.
- `lookupActions` is a hard-coded id: `StandardLookup` makes exactly that component visible when
  the screen is opened as a lookup. Without it a lookup has no Select button.
- `msg:///actions.Select` (three slashes) is a framework message; `msg://customerBrowse.caption`
  resolves in the controller's package (see Messages).
- `<screenSettings>` needs `jmix-ui-data-starter` (Studio adds it only then). `<presentations
  auto="true"/>` is optional.
- `<buttonsPanel>` and `<simplePagination/>` are children of the table element, not siblings.

## Table types

Studio offers `table`, `groupTable`, `dataGrid`, `treeTable`, `treeDataGrid`. The same
`<actions>`/`<buttonsPanel>`/`<simplePagination/>` children apply. The column syntax differs:

```xml
<!-- table / groupTable / treeTable: the column id IS the property path -->
<column id="customer"/>

<!-- dataGrid / treeDataGrid: data comes from `property`; Studio writes both -->
<column property="product" id="product"/>
```

A table `<column id="...">` that does not resolve to a property is NOT an error: the loader keeps
it as a plain id (meant for generated columns), the screen opens, and the column is silently
empty. A typo (`emial`) passes every gate including a UI test that only opens the screen. Check
every column id against the entity attributes. In a `dataGrid` a column without `property` is
likewise a data-less column.

## Choosing list-action types

Standard list action types (`io.jmix.ui.action.list`):

- `create` - opens the editor for a new entity.
- `edit` - opens the editor for the selected entity.
- `view` - opens the editor in read-only mode (`StandardEditor.setReadOnly(true)`); it is a
  mode, not a descriptor attribute. The editor still needs its commit actions.
- `remove` - deletes the selected entities (asks for confirmation).
- `refresh` - reloads the container.
- `add` / `exclude` - for association collections (see `jmix-create-composition-editor`).

`view` REPLACES `edit`, not the whole CRUD bar. "The list opens records read-only" still leaves
`create` and `remove` in place unless creation or deletion is explicitly forbidden.

Configure a standard action from the controller with `@Install`, e.g. initialize new entities:

```java
@Install(to = "customersTable.create", subject = "initializer")
private void customersTableCreateInitializer(Customer customer) {
    customer.setGrade(CustomerGrade.BRONZE);
}
```

`subject` is the setter name without `set` (`setInitializer`, `setAfterCommitHandler`,
`setScreenConfigurer`, `setNewEntitySupplier`, ...). Verify the setter exists on the action class
before writing the subject (`jmix-verify-api-symbol`).

## Hierarchical list

For an entity with a reference to its own class (`Department.parent`):

```xml
<treeTable id="departmentsTable" width="100%" dataContainer="departmentsDc"
           hierarchyProperty="parent">
    <!-- actions, columns, buttonsPanel as in table -->
</treeTable>
```

Load the parent in the fetch plan (`<property name="parent" fetchPlan="_instance_name"/>`).
A tree over a self-reference requires the application to forbid cycles; enforce that at the data
level (`jmix-add-entity-event-listener`), not in the screen.

## Custom buttons MUST carry their own caption

A button bound to a standard action (`customersTable.create`) takes the action's caption. A custom
button has none unless you give it one, and a blank button cannot be found by a tester or a UI test.

```xml
<button id="markActiveBtn" caption="msg://markActiveBtn.caption"/>
```

Handle the click in the controller with `Button.ClickEvent` (`io.jmix.ui.component.Button`):

```java
@Autowired
private GroupTable<Customer> customersTable;
@Autowired
private CollectionLoader<Customer> customersDl;

@Subscribe("markActiveBtn")
public void onMarkActiveBtnClick(Button.ClickEvent event) {
    // ... work with customersTable.getSelected()
    customersDl.load();
}
```

In Classic UI components and containers are injected with `@Autowired` (field name = component
id), not `@ViewComponent`. The field type is the element's interface (`GroupTable` for
`groupTable`, `Table` for `table`, `DataGrid` for `dataGrid`, `TreeTable` for `treeTable`) or one
of its supertypes.

A missing message key does not fail: the caption shows the raw key text. Add the key to
`messages_en.properties` (and every other locale) and look at it.

## Icons

Do not invent icon names. Use `JmixIcon` constant names (`LOOKUP_OK`, `EDITOR_OK`, `SAVE`, ...)
or `font-icon:<VaadinIcons constant>`; grep `JmixIcon` or the project's existing XML (`icon="`)
first. When unsure, omit the `icon` attribute - the button works without it.

## Menu item

```xml
<menu-config xmlns="http://jmix.io/schema/ui/menu">
    <menu id="application" caption="msg://com.company.app/menu.application" insertBefore="administration">
        <item screen="Customer.browse" caption="msg://com.company.app.screen.customer/customerBrowse.caption"/>
    </menu>
</menu-config>
```

The file is the one named by `jmix.ui.menu-config`. The item id defaults to the screen id, so
`@MenuPolicy(menuIds = "Customer.browse")` matches it. In `menu.xml` a caption needs the full
`msg://<group>/<key>` form; with no `caption` the menu looks up `menu-config.<item id>` in the main
message group.

## Messages

`caption="msg://customerBrowse.caption"` resolves in the controller's package group, so the key in
`messages_en.properties` is:

```properties
com.company.app.screen.customer/customerBrowse.caption=Customers
com.company.app.screen.customer/markActiveBtn.caption=Mark active
```

Column headers come from the entity messages (`com.company.app.entity/Customer.name=Name`).

## JPQL entity names

JPQL queries use entity names, not table names: `@Table(name = "SALES_ORDER")` on `SalesOrder` is
still `select e from SalesOrder e`. Use another name only if the entity declares one in JPA metadata.

## Saved user settings outrank the descriptor

With a `<screenSettings auto="true"/>` facet, column width, order and visibility (and sort) are
saved per user in `UI_SETTING` and applied OVER the descriptor on open. After you change columns,
users who already opened the screen still see the old layout, and so does your own browser check.
Clear that user's settings for the screen (or test with a fresh user) before concluding that the
change "did not arrive".

## Proving it

The descriptor is parsed only when the screen opens, so `compileJava` and context start prove
nothing about it. Open the screen in a `@UiTest` (see `jmix-create-test`): with
`jmix-ui-test-assist`, `screens.create(CustomerBrowse.class).show()` throws on a bad component,
action target or missing `@LookupComponent` (when opened as a lookup). It still does not catch an
empty column or a raw message key - assert those explicitly.

## Forbidden

- Flow UI artifacts in a Classic UI project (`StandardListView`, `@ViewController`, `<view>`, `list_*` action types).
- `StandardLookup` without `@LookupComponent`.
- Screen ids that break the `<Entity>.browse` / `<Entity>.edit` conventions without `@PrimaryLookupScreen` / `@PrimaryEditorScreen`.
- Declaring actions without visible buttons or another reachable trigger.
- A button `action="<tableId>.<actionId>"` naming a table id that does not exist (`GuiDevelopmentException: Can't find component` at open).
- Table column ids that are not entity properties (silently empty column).
- Using `@Table` names in JPQL.
- Controller without matching XML descriptor, or descriptor outside the controller's package path.
- Hardcoded caption text; custom buttons without a caption.
- Invented icon names.
- Missing `@ScreenPolicy` / `@MenuPolicy` for the roles that use the screen.
