---
name: jmix-add-dialog-detail-flow
description: Open a Jmix entity detail view from a button/action and refresh related data after save.
---

# Add Dialog Detail Flow

Use this skill when a button or action should create or edit an entity in a modal detail view, or collect a small scalar value through a Jmix input dialog. For parent-owned children edited inside the parent's own detail view via a property-bound `<collection property=...>` container (no query loader), use `jmix-create-composition-detail-view` instead.

## Steps

1. Decide what the button does. If it only collects a scalar value for a service call and creates no entity, read **When the button collects a scalar value for a service call** below. If it now collects a value and calls a service but must create an entity instead, read **When a service-call button must create an entity instead** below. Otherwise continue with the next steps.
2. Inject `DialogWindows` with `@Autowired`. Inject with `@ViewComponent` the loaders to reload, the grid you read, and any child containers that must be cleared.
3. Type the button handler parameter as `ClickEvent<JmixButton>`; see **`IllegalArgumentException: argument type mismatch` at a button click** below.
4. Open `DialogWindows.detail(this, Entity.class).newEntity()` or `.editEntity(entity)`. Use `.withInitializer(...)` to set parent/default fields. If the new entity is a child of the selected master row, read **When the new entity is a child of the selected master row** below.
5. In `.withAfterCloseListener(...)`, reload every affected loader only after `StandardOutcome.SAVE`. Open an independent dialog without `withContainer`, `withField` or `withParentDataContext`; do not attach a container or field only to refresh the opener.
6. A plain `DialogWindows.detail(...)` writes to the database on Save; a later Cancel on the opening view does not undo it. If Save must wait for the opening view's Save, or you pass `withContainer`, `withField` or `withParentDataContext`, read **When Save must wait for the opening view, or you pass a container or field** below.
7. If a child grid shows the rows of the selected master row, read **When a child grid is filtered by the master grid selection** below. If you install a selection listener on the master grid, read **When you install a master grid selection listener** below.
8. Make sure the opened detail view exists and roles have its `@ViewPolicy` (see `jmix-create-detail-view` and `jmix-create-resource-role`).

## Template

```java
@Subscribe("createButton")
public void onCreateButtonClick(final ClickEvent<JmixButton> event) {
    dialogWindows.detail(this, Order.class)
            .newEntity()
            .withAfterCloseListener(closeEvent -> {
                if (closeEvent.closedWith(StandardOutcome.SAVE)) {
                    ordersDl.load();
                }
            })
            .open();
}
```

## `IllegalArgumentException: argument type mismatch` at a button click

This error at the click, before any dialog opens, means the `@Install(subject="clickListener")` / `@Subscribe` handler has the wrong parameter type. The code compiles.

- A `clickListener` delivers a `ClickEvent<JmixButton>` (import `io.jmix.flowui.kit.component.button.JmixButton`). A handler typed `Component` or `ActionPerformedEvent` cannot receive it, so reflection throws.
- The cause is not the `InputParameter` or the dialog. Changing the `InputParameter` type (`intParameter` / `stringParameter` / `withType` / parse) leaves the click broken; fix the handler parameter to `ClickEvent<JmixButton>` first.
- `InputParameter.intParameter("q")` is the correct scalar form; do not switch to `stringParameter` + `Integer.parseInt`.

```java
// WRONG — throws "argument type mismatch" at click:
@Install(to = "actionButton", subject = "clickListener")
private void onClick(final ActionPerformedEvent event) { ... }   // or (Component event)

// RIGHT:
@Subscribe("actionButton")
public void onClick(final ClickEvent<JmixButton> event) { ... }
```

## Forbidden

- Raw Vaadin `Dialog` for entity create/edit flows.
- Raw Vaadin `Dialog` for ordinary scalar input workflows.
- Direct service update when the domain requires creating an entity record.
- An `InputDialog` / `MessageDialog` / service call before the detail dialog when the button should open the detail view directly.
- Refreshing loaders after cancel/close when no save occurred.
- Refreshing grids with `getDataProvider().refreshAll()` instead of loader reload.
- Attaching a container or field to an independent dialog only to refresh the opener.
- Expecting Cancel on the opening view to undo the Save of a plain `DialogWindows.detail(...)`.
- Comparing entity-valued JPQL properties to UUID parameters.
- Using `.selected` inside a `:container_*` JPQL parameter.
- Calling `load()` on a loader after removing a JPQL parameter required by its query.
- A manual-`:param` loader (not `:container_*` / `:component_*`) under `<dataLoadCoordinator auto="true"/>` — it throws at view open.
- No-argument installed selection listeners for `DataGrid` selection changes.
- A button `clickListener` / `@Subscribe` handler typed `Component` or `ActionPerformedEvent` instead of `ClickEvent<JmixButton>`.
- `stringParameter` + `Integer.parseInt` for a numeric input — use `InputParameter.intParameter(...)`.

## Special cases

### When the new entity is a child of the selected master row

```java
@Autowired
private DialogWindows dialogWindows;

@ViewComponent
private DataGrid<Order> ordersDataGrid;

@ViewComponent
private CollectionLoader<Order> ordersDl;

@ViewComponent
private CollectionContainer<OrderLine> orderLinesDc;

@ViewComponent
private CollectionLoader<OrderLine> orderLinesDl;

@Subscribe("createLineButton")
public void onCreateLineButtonClick(final ClickEvent<JmixButton> event) {
    Order order = ordersDataGrid.getSingleSelectedItem();
    if (order == null) {
        return;
    }

    dialogWindows.detail(this, OrderLine.class)
            .newEntity()
            .withInitializer(line -> line.setOrder(order))
            .withAfterCloseListener(closeEvent -> {
                if (closeEvent.closedWith(StandardOutcome.SAVE)) {
                    ordersDl.load();
                    orderLinesDl.load();
                }
            })
            .open();
}
```

### When a child grid is filtered by the master grid selection

Prefer binding to the selected master container:

```xml
<loader id="orderLinesDl" readOnly="true">
    <query><![CDATA[
        select e from OrderLine e
        where e.order = :container_ordersDc
        order by e.createdDate desc
    ]]></query>
</loader>
```

The container parameter itself is the selected item. Do not append `.selected`; never write:

```xml
where e.order = :container_ordersDc.selected
```

A `:container_<DcId>` parameter is bound automatically and may stay under `<dataLoadCoordinator auto="true"/>`. A manual parameter (not `:container_*` / `:component_*`, for example `:param`) is not: a loader that runs with it unset (under `auto="true"`, or `load()` before `setParameter`) throws an `IllegalStateException` at view open about the missing query parameter. Keep such a loader out of the coordinator and load it from the selection handler:

```xml
<facets>
    <!-- coordinator lists only auto-safe loaders; the manual-param loader is NOT here -->
    <dataLoadCoordinator auto="true"/>
</facets>
```

When passing an entity manually, compare the entity-valued property to the entity parameter:

```xml
where e.order = :param
```

When passing only an id manually, compare to the id field:

```xml
where e.order.id = :paramId
```

Never call `load()` after removing a required manual parameter. Bind to the selected master container, skip loading until a master is selected, or clear the child container when no master is selected:

```java
Order order = ordersDataGrid.getSingleSelectedItem();
if (order == null) {
    orderLinesDc.getMutableItems().clear();
    return;
}

orderLinesDl.setParameter("order", order);
orderLinesDl.load();
```

### When you install a master grid selection listener

Use a listener signature that the component accepts. A no-argument installed selection listener is invalid.

```java
import com.vaadin.flow.data.selection.SelectionEvent;

@Install(to = "ordersDataGrid", subject = "selectionListener")
private void ordersDataGridSelectionListener(SelectionEvent<DataGrid<Order>, Order> event) {
    Order order = ordersDataGrid.getSingleSelectedItem();
    if (order == null) {
        orderLinesDc.getMutableItems().clear();
        return;
    }

    orderLinesDl.setParameter("order", order);
    orderLinesDl.load();
}
```

If the project uses `@Subscribe("ordersDataGrid")` for selection changes, copy that existing compiled pattern instead of inventing a new listener form.

### When a service-call button must create an entity instead

Remove the input dialog; do not chain it before the detail dialog. A UI test that clicks the button expects a `StandardDetailView` at once, and casting an `InputDialog` to `StandardDetailView` throws `ClassCastException`.

WRONG (input dialog, then detail dialog):

```java
@Subscribe("actionButton")
public void onActionButtonClick(ClickEvent<JmixButton> event) {
    Order order = grid.getSingleSelectedItem();
    dialogs.createInputDialog(this)
            .withParameters(InputParameter.intParameter("quantity"))
            .withCloseListener(e -> {
                if (e.closedWith(DialogOutcome.OK)) {
                    Integer qty = e.getValue("quantity");
                    // then opens the detail dialog — too late, the test
                    // already saw the input dialog
                    openDetailView(order, qty);
                }
            })
            .open();
}
```

RIGHT (direct detail-dialog open):

```java
@Subscribe("actionButton")
public void onActionButtonClick(ClickEvent<JmixButton> event) {
    Order order = grid.getSingleSelectedItem();
    if (order == null) return;

    dialogWindows.detail(this, OrderLine.class)
            .newEntity()
            .withInitializer(line -> line.setOrder(order))
            .withAfterCloseListener(e -> {
                if (e.closedWith(StandardOutcome.SAVE)) {
                    ordersDl.load();   // reload the loader — NOT grid.getDataProvider().refreshAll()
                }
            })
            .open();
}
```

The detail view collects the scalar attributes, the entity is created on save, and a side effect (for example an `EntityChangedEvent` listener) performs any derived update. "Open the X detail view from the button" means no `InputDialog`, no `MessageDialog`, and no service call before the dialog opens.

### When the button collects a scalar value for a service call

Use the Jmix input dialog API, not a raw Vaadin dialog.

```java
import io.jmix.flowui.Dialogs;
import io.jmix.flowui.app.inputdialog.DialogActions;
import io.jmix.flowui.app.inputdialog.DialogOutcome;
import io.jmix.flowui.app.inputdialog.InputParameter;

@Autowired
private Dialogs dialogs;

@Subscribe("adjustButton")
public void onAdjustButtonClick(final ClickEvent<JmixButton> event) {
    dialogs.createInputDialog(this)
            .withHeader(messageBundle.getMessage("adjustDialog.header"))
            .withParameters(
                    InputParameter.intParameter("quantity")
                            .withLabel(messageBundle.getMessage("adjustDialog.quantity"))
                            .withDefaultValue(0)
            )
            .withActions(DialogActions.OK_CANCEL)
            .withCloseListener(closeEvent -> {
                if (closeEvent.closedWith(DialogOutcome.OK)) {
                    Integer quantity = closeEvent.getValue("quantity");
                    if (quantity != null) {
                        service.adjust(quantity);
                        affectedDl.load();
                    }
                }
            })
            .open();
}
```

- `messageBundle`, `service` and `affectedDl` are the view's existing injected dependencies (`MessageBundle`, your service bean, the affected `CollectionLoader`).
- Use message keys for dialog headers, labels, and notifications.
- Keep service calls in services; the view only collects input, calls the service, and reloads loaders.

### When Save must wait for the opening view, or you pass a container or field

How the dialog was opened decides whether Save writes to the database at once (the default) or merges into the opening view; `@Composition` on the attribute is what switches the default off:

| opened with | parent context | what Save does |
| --- | --- | --- |
| `.withParentDataContext(ctx)` | yes | merges into the parent; reaches the DB when the parent is saved |
| a property-bound `<collection property="x"/>` container where `x` has `@Composition` — passed via `withContainer`, or through `list_create` / `list_edit` on a grid bound to that container | yes | same |
| a field whose value source is a `@Composition` reference (`withField`, one-to-one composition) | yes | same |
| a standalone container with a loader — this is the usual list view, including its standard `list_create` / `list_edit` | **no** | writes to the database immediately; the saved entity is then merged into the opener's `DataContext` for tracking only |
| a property-bound container or a field whose attribute is a plain association (**no** `@Composition`) | **no** | same as above |
| none of the above — plain `DialogWindows.detail(...)` | **no** | writes to the database immediately; Cancel upstream no longer undoes it |

- Passing a container or a field is not enough: without `@Composition` on the attribute, the dialog saves straight to the database.
- A plain `DialogWindows.detail(this, Customer.class).editEntity(customer)` and `list_create` in an ordinary list view are not part of the opener's transaction: Save commits, and a later Cancel on the opening view leaves the commit in place.
- To make Save atomic with the parent, pass `.withParentDataContext(...)` explicitly. Do not rely on a container or a field for it unless the attribute has `@Composition`.

When a parent data context is set up, both views must be able to take part:

- The opened dialog view has no `DataContext` — `DevelopmentException: No DataContext in view '<id>'. Composition editing is impossible.` Add `<data>` with a writable context to the detail view.
- The opening view has a read-only context (`<data readOnly="true">`) — `IllegalArgumentException: Unsupported DataContext type ... Parent DataContext must implement DataContextInternal`. Drop `readOnly` on the opening view.
- The opening view has no `<data>` at all — no error, and no parent context either: the dialog quietly saves to the database.
