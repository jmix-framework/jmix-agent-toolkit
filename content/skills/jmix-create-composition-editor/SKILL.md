---
name: jmix-create-composition-editor
description: Add inline child-collection editing to a Jmix 1.x Classic UI editor - a nested property container, a nested table with create/edit/remove, and the child's own editor - when a parent entity owns its children through @Composition.
---

# Create Composition Editor

Jmix 1.x (verified on 1.4.4), Classic UI. Use this skill when a parent entity owns child entities
(`SalesOrder.lines`) that are edited inside the parent editor through a nested property container
(no query loader). For a button that opens a standalone editor dialog, or a master table that
filters an independently loaded child table, use `jmix-add-dialog-editor-flow` instead.

## How it works (and why `@Composition` is mandatory)

When the nested table's `create`/`edit` action opens the child editor, the framework checks the
parent property. If it is `@Composition`, the child editor's `DataContext` becomes a child of the
parent editor's context:

- OK in the child editor writes the line into the PARENT editor only; nothing reaches the database
  until the parent is committed. Cancelling the parent discards the new lines.
- For a new child the back reference (`line.order`) is set from the parent automatically.
- `remove` on the nested table removes the line from the parent's context, committed with the parent.

Without `@Composition` (a plain `@OneToMany`) the child editor commits straight to the database
on its own OK - before the parent is saved, and outside the parent's Cancel. The screen looks the
same; only the data shows the difference. Model the composition first.

## The child's OWN editor must exist

`create`/`edit` on the nested table open `<Child>.edit`. Without that screen the first click on
"Create" throws `NoSuchScreenException: Screen 'OrderLine.edit' is not defined`. Creating the child
editor (step 2) is not optional, and its id needs a `@ScreenPolicy` as well.

Each button's `action="<tableId>.<actionId>"` must name the nested table's own id and an action
declared in it; a wrong table id fails at open with `GuiDevelopmentException: Can't find component`.

## Steps

1. Make the model a real composition (`jmix-create-entity`):
   - parent collection: `@Composition` + `@OneToMany(mappedBy = "order")`, usually with
     `@OnDelete(DeletePolicy.CASCADE)` so children are deleted with the parent;
   - child: non-null back reference (`@NotNull @ManyToOne(optional = false)` + `nullable = false`
     join column).
2. Create the child editor with `jmix-create-editor-screen` (`OrderLine.edit`). Do not put the
   back-reference field on its form: it is set by the framework.
3. In the parent editor's `<data>` (NOT `readOnly`), include the child property in the parent fetch
   plan and nest `<collection id="linesDc" property="lines"/>` inside the `<instance>`.
4. Add a `table` bound to `linesDc`, with `create`, `edit`, `remove` actions and a `buttonsPanel`
   (Studio wraps it in a `groupBox` captioned with the collection attribute).
5. Add `@ScreenPolicy` for the child editor (`jmix-create-resource-role`).
6. Add messages for the child entity and its editor caption (`jmix-add-i18n-keys`).

## XML pattern (what Studio's editor template generates)

```xml
<data>
    <instance id="salesOrderDc"
              class="com.company.app.entity.SalesOrder">
        <fetchPlan extends="_base">
            <property name="lines" fetchPlan="_base"/>
        </fetchPlan>
        <loader/>
        <collection id="linesDc" property="lines"/>
    </instance>
</data>
...
<layout spacing="true" expand="editActions">
    <form id="form" dataContainer="salesOrderDc">
        <!-- parent fields -->
    </form>
    <groupBox id="linesBox" caption="msg://com.company.app.entity/SalesOrder.lines">
        <table id="linesTable" dataContainer="linesDc" width="100%" height="200px">
            <actions>
                <action id="create" type="create"/>
                <action id="edit" type="edit"/>
                <action id="remove" type="remove"/>
            </actions>
            <columns>
                <column id="product"/>
                <column id="quantity"/>
            </columns>
            <buttonsPanel>
                <button action="linesTable.create"/>
                <button action="linesTable.edit"/>
                <button action="linesTable.remove"/>
            </buttonsPanel>
        </table>
    </groupBox>
    <hbox id="editActions" spacing="true">
        <button id="commitAndCloseBtn" action="windowCommitAndClose"/>
        <button id="closeBtn" action="windowClose"/>
    </hbox>
</layout>
```

The nested `<collection>` takes `property` only - no `class`, loader or query.

The child editor opens in the current tab by default. To make it a dialog, give the child editor
`<dialogMode height="AUTO" width="AUTO" modal="true" forceDialog="true"/>` (Studio's "modal dialog"
option), or set the action's open mode with nested properties:

```xml
<action id="create" type="create">
    <properties>
        <property name="openMode" value="DIALOG"/>
    </properties>
</action>
```

## Associations are not compositions

For a collection the parent does NOT own, Studio generates different actions:

- `@ManyToMany`: `add` (pick existing entities in a lookup screen) and `exclude` (remove from the
  collection without deleting the entity);
- `@OneToMany` without `@Composition`: `create`/`edit` + `exclude`.

`exclude` works only on nested containers. Do not use `remove` on an association: it deletes the
referenced entity itself.

## Parent-level rules

Validate the aggregate in the parent editor, e.g. "at least one line", with a `ValidationEvent`
handler (see `jmix-create-editor-screen`); the child editor sees only one line.

## Proving it

In a `@UiTest` (`jmix-create-test`): open the parent editor for a new entity, run
`linesTable.getActionNN("create").actionPerform(linesTable)`, find the opened `OrderLineEdit`,
assert its `getEditedEntity().getOrder()` equals the parent, fill it and `closeWithCommit()`. Then
assert the line is in the parent's `linesDc` but NOT yet in the database, commit the parent and
assert it is now. Removing `@Composition` makes exactly the "not yet in the database" assertion fail.

## Forbidden

- Nested `create`/`edit` actions without a child editor (`<Child>.edit`).
- Child actions without visible buttons or another reachable trigger.
- A parent collection edited inline without `@Composition` (children commit on their own).
- `<data readOnly="true">` in the parent editor (its no-op context saves nothing).
- Nullable child back reference; the back-reference field on the child form.
- `remove` on an association collection where `exclude` is meant.
- Missing `@ScreenPolicy` for the child editor.
- Editing composition children outside the parent aggregate when the domain says they are owned.
