---
name: jmix-create-detail-view
description: Create a Jmix Flow UI detail view with XML descriptor, save-close action, messages, and policies.
---

# Create Detail View

## Steps

1. Create the Java controller under `view/<entityname>/`.
2. Extend `StandardDetailView<Entity>`.
3. Add `@Route(value = ".../:id", layout = MainView.class)`. In a Jmix add-on module, which has no `MainView` and must not reference the application, use `layout = DefaultMainViewParent.class` (`io.jmix.flowui.view.DefaultMainViewParent`); the application's main view is used as the parent at runtime.
4. Add `@ViewController(id = "Entity.detail")`.
5. Add `@ViewDescriptor(path = "entity-detail-view.xml")`.
6. Add `@EditedEntityContainer("<entity>Dc")`.
7. Create the XML descriptor with instance container, loader, `dataLoadCoordinator`, typed form fields, `detail_saveClose`, and `detail_close`. If the view shows a to-many attribute, read **When the view shows a to-many attribute** below. If the form has a `tabSheet`, read **When the form has a `tabSheet`** below.
8. Configure reference fields with a verified data source: lookup action, `itemsContainer`, or `itemsQuery`; read **When the entity has a reference attribute** below.
9. Use `InitEntityEvent` for UI-only defaults only. A required persistent default belongs at the entity layer — see **Required-field defaults** in `jmix-create-entity`.
10. If the save needs cross-field or manual validation, read **When the save needs cross-field or manual validation** below. If the save must ask the user for confirmation, read **When the save must ask the user for confirmation** below.
11. Add message keys for the title and field labels.
12. Grant access for roles that can open the detail view with `@ViewPolicy(viewIds = "Entity.detail")` — declared on a **method of a `@ResourceRole` interface** (the annotation is `@Target(METHOD)`), not on the view controller. The annotation has no `value()` member: `@ViewPolicy("...")` does not compile; use `viewIds = "..."` (or `viewClasses = ...`). See `jmix-create-resource-role`.
13. Before finishing, compare every form field component against the Java property type (**Final XML Type Audit**).

## Two render-time failures that compile clean

`compileJava` does not check `*-view.xml`, so both pass it and throw when the view is opened. Only a Jmix-aware inspection catches them; the mechanical checks do not. With no inspection, write them right from the start:

1. **An enum attribute is never `entityComboBox`.** `entityComboBox` is for entity references; binding it to an enum (with or without a made-up `enumClass` attribute) throws `IllegalStateException: Range is enumeration` at render. There is no `enumClass` attribute on `entityComboBox`. For a Jmix enum property use a plain `<comboBox>` or `<select>`; Jmix fills it from the enum:

   ```xml
   <!-- WRONG: <entityComboBox property="category" enumClass="...SomeEnum"/> -->
   <comboBox id="categoryField" property="category"/>   <!-- enum: just bind the property -->
   ```

2. **`itemsQuery` must wrap its JPQL in a nested `<query>` element**, and that query must reference `:searchString` (the combo passes it for type-ahead). Raw CDATA directly under `<itemsQuery>` throws `GuiDevelopmentException: Nested 'query' element is missing`; a query that ignores `:searchString` throws `DevelopmentException: Parameter 'searchString' is not used in the query` at dropdown fetch. The correct shape is in **When the entity has a reference attribute** below.

## Controller Template

```java
@Route(value = "customers/:id", layout = MainView.class)
@ViewController(id = "Customer.detail")
@ViewDescriptor(path = "customer-detail-view.xml")
@EditedEntityContainer("customerDc")
public class CustomerDetailView extends StandardDetailView<Customer> {
}
```

## XML Skeleton

```xml
<view xmlns="http://jmix.io/schema/flowui/view"
      title="msg://customerDetailView.title"
      focusComponent="form">
    <data>
        <instance id="customerDc" class="com.company.app.entity.Customer">
            <fetchPlan extends="_base"/>
            <loader id="customerDl"/>
        </instance>
    </data>
    <facets>
        <dataLoadCoordinator auto="true"/>
    </facets>
    <actions>
        <action id="saveCloseAction" type="detail_saveClose"/>
        <action id="closeAction" type="detail_close"/>
    </actions>
    <layout>
        <formLayout id="form" dataContainer="customerDc">
            <textField id="nameField" property="name"/>
        </formLayout>
        <hbox id="detailActions">
            <button id="saveAndCloseButton" action="saveCloseAction"/>
            <button id="closeButton" action="closeAction"/>
        </hbox>
    </layout>
</view>
```

Always declare both `detail_saveClose` and `detail_close`: a detail view without a save action is broken for create flows. Use editable form components (`textField`, `comboBox`, `entityComboBox`, etc.) without hard-coded `readOnly="true"`, unless an attribute is permanently read-only in domain terms (for example audit timestamps). If the task says records open in read mode, read **When the task says records open in read mode** below.

Do not expose technical fields (`id`, `version`) in user-facing forms. Hide parent/default fields only when they are initialized elsewhere.

To style a field, a card, or a component you build in the controller (CSS classes, theme variants, `getStyle().set(...)`, `--aura-*` / `--lumo-*` tokens), read `jmix-style-ui` first: a token the active theme does not define fails silently and passes every gate.

## Field Component Mapping

| Property type | Component |
| --- | --- |
| `String` short text | `textField` |
| `String` long text | `textArea` |
| `Integer` | `integerField` |
| `Long` | `integerField` or `numberField` according to project usage |
| `BigDecimal` | `bigDecimalField` |
| `Boolean` | `checkbox` |
| `LocalDate` | `datePicker` |
| `LocalDateTime` | `dateTimePicker` |
| Jmix enum | `select` or `comboBox` |
| Entity reference | `entityComboBox` or `entityPicker` |

If a free-text field uses `valueChangeMode` `EAGER`, `LAZY`, or `TIMEOUT`, read **When a text field has a live `valueChangeMode`** below. If a `comboBox` gets its items in the controller, read **When a `comboBox` gets its items in the controller** below.

A checkbox bound to a `@NotNull Boolean` takes the required state from the entity, but Vaadin treats an unchecked checkbox as empty: the form rejects `false` and save leaves the view open. When unchecked `false` is a valid value, declare `required="false"`; the entity constraint still rejects `null`:

```xml
<checkbox id="subscribedField" property="subscribed" required="false"/>
```

## Final XML Type Audit

After creating or editing the descriptor, inspect each field:

- `Integer` is not a `textField`; use `integerField`.
- `BigDecimal` is not a `textField`; use `bigDecimalField`.
- Date/time properties use date/time picker components.
- Boolean properties use checkbox or the project's boolean component pattern. A checkbox bound to an `@NotNull Boolean` that may be `false` declares `required="false"`.
- Entity references use reference components, not text fields.
- A free-text field with `valueChangeMode` `EAGER`, `LAZY`, or `TIMEOUT` keeps whitespace while typing (`trimEnabled="false"`).
- A `comboBox` whose items are set in `BeforeShowEvent` is not bound in the descriptor.

If an existing project uses a different compiled pattern for a type, follow the existing pattern and keep it consistent.

## Forbidden

- Using list-view route or id patterns for detail views.
- Missing `detail_saveClose`, or a "read-only" detail view with only `detail_close` and every field `readOnly="true"`.
- Using `textField` for numeric, date/time, boolean, or reference properties.
- `entityComboBox` for an enum attribute, or an `enumClass` attribute on it (`Range is enumeration` at render).
- `itemsQuery` JPQL without a nested `<query>` element, or without `:searchString`.
- `itemsQuery` without `searchStringFormat` and `escapeValueForLike` (empty dropdown, every gate green).
- Reference fields without a working lookup action, `itemsContainer`, or verified `itemsQuery`.
- Using `@Table` names in `itemsQuery`.
- `itemsQuery` with unresolved `container_` or `component_` parameters.
- Invented action ids on `entityPicker`; use `entity_lookup` and `entity_clear`.
- A required persistent default set only in `InitEntityEvent`.
- Hardcoded labels or titles.
- Hiding required fields without setting defaults elsewhere.
- Exposing `id` or `version` in user-facing forms.
- A checkbox bound to an `@NotNull Boolean` without `required="false"` when unchecked `false` is a valid value.
- `@ViewPolicy` on the view controller, or `@ViewPolicy("...")` without `viewIds =`.
- Missing view policy for dialog-opened detail views.
- A `comboBox` bound in the descriptor while its items are set in `BeforeShowEvent`.
- A confirmation dialog in `ValidationEvent`, or in `BeforeSaveEvent` without `preventSave()` / `resume()`.
- A `class` attribute on a nested property-bound `<collection property="..."/>`.
- `<markdown>` with an empty or absent `content` attribute (throws at view load), or a guessed `io.jmix.flowui...Markdown` import.
- CSS custom properties from a theme the app does not run (e.g. `--lumo-*` in an Aura app) — see `jmix-style-ui`.

## Special cases

### When the entity has a reference attribute

For `@ManyToOne` and other entity references, pick the pattern by the candidate set:

- **`entityComboBox` with `itemsQuery` — preferred.** The JPQL runs against the database on every type-ahead and fetches only matching candidates. Use it for any non-trivial candidate set.
- **`entityComboBox` with `itemsContainer`** — for small, fixed sets that fit in memory and rarely change. Loaded once at view open.
- **`entityPicker`** with lookup and clear actions — when users need a full lookup screen. Use the standard action ids `entity_lookup` and `entity_clear` exactly; do not invent ids.

**`itemsQuery` shape.** The JPQL must use `like :searchString`. The parameter is the bare combo input unless `searchStringFormat` wraps it: an empty string when the dropdown opens, so `like ''` returns no rows, and the exact, case-sensitive text afterwards. Set the format and the escaping on the `itemsQuery` element; without them every gate stays green and only the browser shows an empty dropdown. The JPQL must use the JPA/Jmix entity name, not the database table name.

```xml
<entityComboBox id="refField" property="ref">
    <itemsQuery class="com.company.app.entity.Ref"
                searchStringFormat="(?i)%${inputString}%"
                escapeValueForLike="true">
        <query>
            <![CDATA[
            select e from Ref e
            where e.name like :searchString escape '\'
            order by e.name
            ]]>
        </query>
    </itemsQuery>
</entityComboBox>
```

A UI test that fetches the picker's items only with a partial filter does not catch a missing `searchStringFormat`; fetch with the empty filter too.

`itemsQuery` does not bind `:container_*` / `:component_*` parameters. When the reference list depends on another component or container, use `itemsContainer` with a regular loader.

**`itemsContainer`.** Declare a `<collection>` for the candidate entities and point the combo at it; `<dataLoadCoordinator auto="true"/>` loads it at open:

```xml
<data>
    <instance id="<entity>Dc" class="com.company.app.entity.<Entity>">
        <fetchPlan extends="_base">
            <property name="ref" fetchPlan="_instance_name"/>
        </fetchPlan>
        <loader id="<entity>Dl"/>
    </instance>
    <collection id="refsDc" class="com.company.app.entity.Ref">
        <fetchPlan extends="_instance_name"/>
        <loader id="refsDl">
            <query><![CDATA[select e from Ref e order by e.name]]></query>
        </loader>
    </collection>
</data>
...
<entityComboBox id="refField" property="ref" itemsContainer="refsDc"/>
```

Before finishing, verify that saved reference entities can appear in the component data provider. If a field is required, do not leave a reference component without a working item source or lookup action.

### When a text field has a live `valueChangeMode`

For free-text fields with `EAGER`, `LAZY`, or `TIMEOUT` value updates, set `trimEnabled="false"`. Otherwise a client-originated update can trim the trailing space or newline and rewrite the text before the user types the next word:

```xml
<textArea id="descriptionField" property="description"
          valueChangeMode="TIMEOUT" trimEnabled="false"/>
```

If normalization is required, do it at an explicit commit or validation boundary. Test a client-originated value ending in a space and a newline (or real typing), not only server-side `setValue`, which bypasses this trimming.

### When a `comboBox` gets its items in the controller

If the items are set in `BeforeShowEvent`, do not bind the `comboBox` in the descriptor: the binding sets the value when the entity arrives, before `setItems`, and opening a saved record fails. Either call `setItems(…)` in `InitEvent`, or bind with `setValueSource(new ContainerValueSource<>(container, "property"))`.

### When the view shows a to-many attribute

To show a to-many composition or association (`Order.products`, `Customer.tags`), nest a property-bound `<collection>` inside the `<instance>` container and bind a `dataGrid` to it:

```xml
<instance id="orderDc" class="com.company.app.entity.Order">
    <fetchPlan extends="_base">
        <property name="products" fetchPlan="_instance_name"/>
    </fetchPlan>
    <loader id="orderDl"/>
    <!-- property-bound: NO class, NO loader, NO query -->
    <collection id="productsDc" property="products"/>
</instance>
```

```xml
<dataGrid id="productsDataGrid" dataContainer="productsDc" width="100%">
    <columns>
        <column property="name"/>
    </columns>
</dataGrid>
```

A top-level `<collection>` (a list view's own loader) requires `class`. A nested property-bound collection takes `property` and nothing else — no `class`, no loader, no query; the container gets its metaclass from the property, so a `class` attribute is a descriptor defect. The parent's fetch plan must include the property, or the grid is empty (see `jmix-configure-fetch-plan`).

For a read-only grid, declare no `list_create` / `list_edit` / `list_remove` actions on it.

### When the task says records open in read mode

"The list opens records in read mode" or "the detail view is opened with the `read` action" means read-only open mode, set on the list side. It is not a read-only descriptor.

Set it in the list view: open action `list_read` instead of `list_edit`. Existing rows open as a non-editable form, new entities still open writable through `list_create`, and Jmix makes the fields read-only at runtime. The detail XML stays a normal writable descriptor with `detail_saveClose` and editable fields.

Do not build a read-only descriptor (every field `readOnly="true"`, only `detail_close`): it is always read-only, even for new entities, and cannot create entities or save edits.

### When the save needs cross-field or manual validation

Add a `@Subscribe` handler on `ValidationEvent` and report failures with `event.getErrors().add("...")`. For programmatic checks (for example before a custom save) use the `ViewValidation` bean (`validateUiComponents`, `showValidationErrors`).

### When the form has a `tabSheet`

Do not rely only on `required` or field validators for an invariant on a secondary tab. Inactive tab content is disabled, and field validation skips disabled components. Keep those checks as UI hints, but enforce the save invariant in a `ValidationEvent` handler that reads `getEditedEntity()`, not only the enabled fields. Test saving without visiting the secondary tab and after switching away from it; neither path may save invalid state.

### When the save must ask the user for confirmation

`ValidationEvent` can only reject a save; it cannot ask a question and continue. The only hook that suspends a save and resumes it afterwards is `StandardDetailView.BeforeSaveEvent` with `preventSave()` / `resume()`:

```java
@Autowired
private Dialogs dialogs;

@Subscribe
public void onBeforeSave(final BeforeSaveEvent event) {
    if (!reissuesRelatedCodes()) {
        return;
    }
    event.preventSave();
    dialogs.createOptionDialog()
            .withHeader(messageBundle.getMessage("confirmDialog.header"))
            .withText(messageBundle.getMessage("confirmDialog.text"))
            .withActions(
                    new DialogAction(DialogAction.Type.YES)
                            .withHandler(e -> event.resume()),
                    new DialogAction(DialogAction.Type.NO))
            .open();
}
```

`Dialogs.createOptionDialog()` takes no view argument, unlike `createInputDialog(View)`. Without `preventSave()` the save runs regardless of what a dialog shows, so a home-made confirmation dialog does not stop it.
