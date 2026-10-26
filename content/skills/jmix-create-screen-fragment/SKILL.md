---
name: jmix-create-screen-fragment
description: Create or change reusable Jmix Classic UI screen fragments (ScreenFragment + fragment XML), embed them declaratively or via Fragments, pass properties, share host data containers with provided="true", and exchange events with the host screen.
---

# Create Screen Fragment

Stack: Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui`, Vaadin 8).

Use this skill when UI should be reusable inside one or more screens or fragments.
This is Classic UI: a fragment is a `ScreenFragment` with `@UiController` +
`@UiDescriptor` and a `<fragment>` descriptor with a `<layout>` root. There is no
`Fragment<RootType>` generic, no `@FragmentDescriptor`, no `<content>`, no
`fragmentDataLoadCoordinator` — those are Flow UI (Jmix 2.x/3).

## Steps

1. Confirm the UI is reusable enough to justify a fragment; keep one-off layout inside
   the screen.
2. Create the controller in the relevant `screen/...` package: extend `ScreenFragment`,
   add `@UiController("<FragmentId>")` and `@UiDescriptor("<file>.xml")` (Studio:
   **New → Screen → Screen fragment** / **Entity fragment**).
3. Create the descriptor with namespace `http://jmix.io/schema/ui/fragment`; the
   required root is `<layout>`. Optional before it: `<data>`, `<actions>`, `<facets>`.
4. Add `<data>` only for data the fragment owns; mark host-owned containers/loaders
   with `provided="true"`.
5. Load the fragment's own loaders with `<facets><dataLoadCoordinator auto="true"/>`
   (the same facet name as in screens) or explicitly in an event handler.
6. Pass parameters through public setters: `<properties>` in XML, or call the setter
   before adding the fragment programmatically. Read XML properties in `AttachEvent`,
   not `InitEvent` (pitfall below).
7. Give the embedded `<fragment>` an `id` when the host subscribes to its events or
   looks it up.
8. Add message keys for user-visible captions (`jmix-add-i18n-keys`); `msg://` in a
   fragment descriptor resolves against the fragment's package.
9. Open the host in a `@UiTest` (see **Verify**).

## Controller Template

```java
import io.jmix.ui.screen.*;

@UiController("CustomerInfoFragment")
@UiDescriptor("customer-info-fragment.xml")
public class CustomerInfoFragment extends ScreenFragment {
}
```

Components, containers and beans are injected with `@Autowired` exactly as in a screen.
The fragment's lifecycle events are `ScreenFragment.InitEvent`, `AfterInitEvent`,
`AttachEvent`, `DetachEvent` — there is no `BeforeShowEvent` / `ReadyEvent` on a
fragment.

## XML Skeleton

```xml
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<fragment xmlns="http://jmix.io/schema/ui/fragment">
    <data>
        <instance id="customerDc" class="com.company.app.entity.Customer" provided="true"/>
        <collection id="contactsDc" class="com.company.app.entity.Contact">
            <fetchPlan extends="_base"/>
            <loader id="contactsDl">
                <query>
                    <![CDATA[select e from Contact e where e.customer = :container_customerDc]]>
                </query>
            </loader>
        </collection>
    </data>
    <facets>
        <dataLoadCoordinator auto="true"/>
    </facets>
    <layout spacing="true">
        <label id="contactCountLabel"/>
        <table id="contactsTable" width="100%" height="150px" dataContainer="contactsDc">
            <columns>
                <column id="name"/>
            </columns>
        </table>
        <button id="confirmBtn" caption="msg://confirmBtn.caption"/>
    </layout>
</fragment>
```

A fragment loader may reference a provided container with `:container_<id>`: the auto
coordinator then reloads it when the host's item changes (verified: a provided
`customerDc` set by the host editor loads the fragment's `contactsDc`). A loader with
no parameters is loaded on the fragment's `AttachEvent`.

## Embedding

Declarative — `screen` is the fragment's `@UiController` id, not the class:

```xml
<groupBox id="summaryBox" caption="msg://customerInfoFragment.title">
    <fragment id="customerInfoFragment" screen="CustomerInfoFragment">
        <properties>
            <property name="showContactCount" value="true"/>
        </properties>
    </fragment>
</groupBox>
```

`<property>` takes either `value` (parsed into the setter's type: `String`, boxed or
primitive numbers, `boolean`) or `ref` — the id of a host component, data container or
data loader, injected when the setter's parameter type is `Component`,
`InstanceContainer` or `DataLoader`. A `value` is passed as-is: `msg://` is NOT
resolved there. An unparseable value or an unknown component `ref` is only logged at
INFO and the setter is not called; an unknown container/loader `ref` throws
`IllegalArgumentException: Container '<id>' not found` (or `Loader ...`). The ref is
looked up in the HOST screen, not in the fragment.

Programmatic — create through the `Fragments` bean, call setters, then add
`getFragment()` to a container (in the host's `InitEvent` or later):

```java
@Autowired
private Fragments fragments;
@Autowired
private VBoxLayout extraBox;

@Subscribe
public void onInit(InitEvent event) {
    CustomerInfoFragment fragment = fragments.create(this, CustomerInfoFragment.class);
    fragment.setShowContactCount(false);   // before adding
    extraBox.add(fragment.getFragment());
}
```

## Pitfall: XML properties are not set yet in InitEvent

In 1.4.4 the properties of a declaratively embedded fragment are injected AFTER the
fragment's `InitEvent` and `AfterInitEvent` have fired (`FragmentHelper`), and before
`AttachEvent`. A setter value read in `onInit` is still the field default — verified:
a label made visible from `showContactCount` in `InitEvent` stayed hidden, in a
`@UiTest` and in the browser. The 1.4 docs say otherwise; the code wins. Read properties
in `AttachEvent`:

```java
private boolean showContactCount;

public void setShowContactCount(boolean showContactCount) {
    this.showContactCount = showContactCount;
}

@Subscribe
public void onAttach(AttachEvent event) {
    contactCountLabel.setVisible(showContactCount);
}
```

For programmatic embedding the setter runs before `add(...)`, so both events see it;
`AttachEvent` is the handler that works for both ways of embedding.

## Provided Data Components

`provided="true"` means "a container/loader with this id exists in the host screen
(or the enclosing fragment)". All attributes except `id` are ignored at runtime and
kept only for Studio:

```xml
<instance id="customerDc" class="com.company.app.entity.Customer" provided="true"/>
<loader id="customersDl" provided="true"/>
```

The host and all its fragments share ONE `DataContext`: entities a fragment loads are
merged into it and committed with the host editor.

A provided id with no host counterpart compiles clean and fails when the fragment is
created: `IllegalArgumentException: Container 'customerDc' not found` (verified by
creating the fragment in a host without that container).

## Host Events in the Fragment

Subscribe to the host screen's events with `Target.PARENT_CONTROLLER`; any screen event
works, including the editor's `InitEntityEvent`:

```java
@Subscribe(target = Target.PARENT_CONTROLLER)
public void onHostAfterShow(Screen.AfterShowEvent event) {
    contactCountLabel.setDescription(customerDc.getItem().getName());
}
```

`getHostScreen()` / `getHostController()` are available from `AttachEvent` on.

## Fragment Events in the Host

Declare an event class, a public `add...Listener` method that RETURNS `Subscription`,
and fire it with `fireEvent`:

```java
import io.jmix.core.common.event.Subscription;
import java.util.EventObject;
import java.util.function.Consumer;

public static class NameConfirmedEvent extends EventObject {
    private final Customer customer;

    public NameConfirmedEvent(CustomerInfoFragment source, Customer customer) {
        super(source);
        this.customer = customer;
    }

    public Customer getCustomer() {
        return customer;
    }
}

public Subscription addNameConfirmedListener(Consumer<NameConfirmedEvent> listener) {
    return getEventHub().subscribe(NameConfirmedEvent.class, listener);
}

@Subscribe("confirmBtn")
public void onConfirmBtnClick(Button.ClickEvent event) {
    fireEvent(NameConfirmedEvent.class, new NameConfirmedEvent(this, customerDc.getItem()));
}
```

Host side — the fragment `id` plus `Target.CONTROLLER`:

```java
@Subscribe(id = "customerInfoFragment", target = Target.CONTROLLER)
public void onCustomerInfoFragmentNameConfirmed(CustomerInfoFragment.NameConfirmedEvent event) {
    notifications.create().withCaption(event.getCustomer().getName()).show();
}
```

The injector finds the listener method by its `Consumer<EventType>` parameter, and
only among methods named `add*` returning `Subscription` (or `set*` returning `void`).
A `void addXxxListener(...)` is not found: `DevelopmentException: Target ... does not
support event type ...` when the host opens.

## Fragment as a table cell

To render a reusable fragment in a table column, create it with `Fragments` in a column
generator (`@Install(to = "<tableId>.<columnId>", subject = "columnGenerator")`, a
method taking the row entity and returning `Component`) and return
`fragment.getFragment()`. Keep such fragments read-only and light: one is created per
rendered row.

## Verify — fragment wiring fails when the host opens, not at compile or context start

A missing provided container, a wrong `screen` id, a bad descriptor, or an
`add...Listener` the injector cannot find all compile clean, and in 1.4.4 a plain
context-load test does not parse screen XML either. Open the host in a `@UiTest`
(`jmix-create-test`; needs `testImplementation 'io.jmix.ui:jmix-ui-test-assist'`):

```java
@Test
void customerEditHostsFragments(Screens screens) {
    CustomerEdit editor = screens.create(CustomerEdit.class);
    editor.setEntityToEdit(customer);
    editor.show();

    Fragment declared = (Fragment) editor.getWindow().getComponentNN("customerInfoFragment");
    assertTrue(declared.getComponentNN("contactCountLabel").isVisible());
    ((Button) declared.getComponentNN("confirmBtn")).click();   // fires the host handler
}
```

Use `io.jmix.ui.component.Fragment` for the cast and get inner components through the
fragment (`declared.getComponentNN(...)`), or through the fragment controller's
`getFragment()`; `UiControllerUtils.getScreenData(fragmentController)` reaches its data.
Before typing an API, check it in the 1.x jars (`jmix-verify-api-symbol`).

## Forbidden

- Flow UI fragment API in a 1.x project: `Fragment<...>` as a controller base class,
  `@FragmentDescriptor`, `<content>`, `fragmentDataLoadCoordinator`,
  `getFragmentData()`.
- A fragment controller without its XML descriptor, or a descriptor without `<layout>`.
- `<fragment class="...">` — the host attribute is `screen="<UiController id>"`.
- Reading XML `<properties>` values in the fragment's `InitEvent` / `AfterInitEvent`.
- `provided="true"` without a same-id container/loader in the host.
- An `add...Listener` for a fragment event that does not return `Subscription`.
- One-off screen layout extracted into a fragment without reuse or isolation benefit.
- Hardcoded user-visible captions; `msg://` inside a `<property value>` (not resolved).
