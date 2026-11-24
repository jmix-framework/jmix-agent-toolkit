---
name: jmix-create-test
description: Create or update Jmix unit, integration, UI integration, or end-to-end tests for services, entity listeners, security behavior, views, fragments, and persistence workflows.
---

# Create Test

## Steps

1. Choose the smallest test type that proves the behavior.
2. Use a plain JUnit test for pure Java logic without Spring/Jmix services.
3. Use `@SpringBootTest` for services, DataManager persistence, entity listeners, security, and transactions.
4. Use `@UiTest` with `FlowuiTestAssistConfiguration` for Flow UI controller/component behavior without a browser. This includes the minimal test that opens a view for Gate 3 of `jmix-verify-bootrun`. Read **When you write a UI integration test (`@UiTest`)** below. If the test checks grid columns or form fields hidden by security, also read **When a UI test checks columns or fields hidden by security** below.
5. Use end-to-end browser tests only for real browser behavior, routing, login, theme, or Vaadin client-side interactions. Read **When the behavior needs a real browser** below.
6. Create test data through `DataManager.create()` and `DataManager.save()`.
7. Set authentication with the project's `AuthenticatedAsAdmin` extension or `SystemAuthenticator`. If the code under test runs on a scheduler, `@Async`, or application event listener path, read **When the code under test runs outside a user session** below.
8. Clean up created persistent data in `@AfterEach`. If an entity has `@DeletedDate`/`@DeletedBy`, read **When the test removes a soft-deletable entity** below.
9. Mock external systems at the boundary with `@MockitoBean`. Jmix 3 runs on Spring Boot 4, which removed `@MockBean`.
10. Run the smallest relevant Gradle test command.
11. Before finishing, go through **Final review** below.

Before typing any Jmix/Vaadin symbol you didn't copy from this project's `src` — a class, enum constant, action id, component, or event inner-class — verify it with `jmix-verify-api-symbol`.

## Unit test pattern

```java
class PriceCalculatorTest {
    private final PriceCalculator calculator = new PriceCalculator();

    @Test
    void appliesDiscount() {
        assertThat(calculator.applyDiscount(100, 10)).isEqualTo(90);
    }
}
```

Do not create an unregistered anonymous or local subclass of a Jmix entity for an in-memory fixture. The class is still on the test classpath: Jmix metadata discovery in another test can find it and fail with a missing metaclass, even when the fixture's own unit test passes.

- To test a missing-handler branch, vary the injected registry or collaborator list and use an existing entity type.
- If a new subtype is really needed, register it through the supported test configuration and run the full suite with a fresh context. Running only the fixture's unit test does not check metamodel discovery.

## Integration test pattern

```java
@SpringBootTest
@ExtendWith(AuthenticatedAsAdmin.class)
class CustomerServiceTest {
    @Autowired
    private DataManager dataManager;

    @Autowired
    private CustomerService customerService;

    private final List<Object> cleanup = new ArrayList<>();

    @Test
    void findsCustomerByEmail() {
        Customer customer = dataManager.create(Customer.class);
        customer.setEmail("customer@test.com");
        cleanup.add(dataManager.save(customer));

        assertThat(customerService.findByEmail("customer@test.com")).isPresent();
    }

    @AfterEach
    void tearDown() {
        cleanup.forEach((entity) -> dataManager.load(Id.of(entity)).optional().ifPresent(dataManager::remove));
    }
}
```

Cleanup reloads by id and then removes. The code under test (a service method, an entity event listener) may save the entity again, so the instance in the cleanup list can have an old version, and removing it throws an optimistic-lock exception.

## Security test pattern

```java
Optional<Customer> result = systemAuthenticator.withUser(
        username,
        () -> customerService.findByEmail("customer@test.com")
);
```

Use this when the expected result depends on Jmix security policies.

Test row-level rules by loading data as the user and asserting which rows come back. A permission API such as `SecureOperations` proves only that a policy exists.

If the test checks grid columns or form fields hidden by attribute permissions, read **When a UI test checks columns or fields hidden by security** below.

## Final review

Before finishing, check:

- Every created persistent record is removed in `@AfterEach`, using the authentication level needed for deletion.
- Cleanup reloads by id and then removes, instead of removing an instance that can be stale.
- `@AfterEach` deletes child rows (with a `@ManyToOne`/`@JoinColumn` to another cleaned-up entity) before the parents they reference. Check the order again when a new FK is added to an entity that existing cleanup already covers. A wrong order throws a constraint violation in teardown, and JUnit reports it against the test, so it looks like a test bug.
- If an entity has `@DeletedDate`/`@DeletedBy`, read **When the test removes a soft-deletable entity** below.
- No `@Transactional` on the test class or methods: it rolls back the writes that `@AfterEach` cleanup and the second back-to-back run depend on.
- An in-memory datasource with a fixed name (`jdbc:hsqldb:mem:<fixed>`) is shared by every `@SpringBootTest` context in the JVM that uses it. It is not reset per class or per method (HSQLDB registers a `mem:` catalog by name for the JVM's lifetime). So:
  - `@AfterEach` cleanup is required even for a test that only reads, or a later test in the same run sees its rows.
  - A test that calls a method twice to prove idempotency must not expect a fresh precondition between the calls. Set up explicitly the precondition that the code under test checks.
- Test data has unique values to avoid collisions.
- Assertions verify persisted or visible behavior, not only the absence of exceptions.
- A test that compares a stored date-time with its in-memory original (equality, "same event", `isEqual`) creates the value at the column precision, for example `OffsetDateTime.now().truncatedTo(ChronoUnit.MICROS)` for a PostgreSQL `timestamp`. `now()` has nanoseconds on Linux JDKs and microseconds on macOS, and the driver rounds the value to the column on write, so the reloaded value differs about half the time: green on a developer Mac, red on Linux CI.
- The test command can run one class or method without running the full suite.
- Run the single class twice back-to-back. A second green run shows there are no leftover rows and no dependence on data from other tests.
- For a UI test: it runs as a real database user when the behavior depends on the current user, and it selects the `tabSheet` tab before `click()` on a component in that tab (see **When you write a UI integration test (`@UiTest`)** below).

## Forbidden

- `@Transactional` on test classes/methods — it rolls back writes, so `@AfterEach` cleanup of committed entities and running the test twice back-to-back both stop working.
- `@MockBean` — removed in Spring Boot 4; use `@MockitoBean`.
- `new Entity()` or constructor-created Jmix entities in persistence tests.
- An unregistered anonymous or local subclass of a Jmix entity as a test fixture.
- Removing the saved instance in cleanup instead of reloading it by id.
- Tests that depend on data left by previous tests.
- Cleanup only at the end of the test method.
- Deleting parents before the child rows that reference them in `@AfterEach`.
- `dataManager.remove` as the only cleanup of a soft-deletable entity.
- Test data without unique values.
- A test that asserts only that nothing was thrown.
- An idempotency test that expects a fresh precondition between its two calls on a shared fixed-name HSQLDB `mem:` datasource.
- Comparing a reloaded date-time with an original from `now()` that is not truncated to the column precision.
- Checking row-level rules only through a permission API such as `SecureOperations`.
- `spring.main.allow-bean-definition-overriding=true` to replace a bean for one test — use a distinct `@Primary` bean instead.
- `@WithUserDetails` for Jmix security tests when `SystemAuthenticator` or the project auth extension is available.
- Authenticating before calling a scheduler/`@Async` entry point and then claiming that path is covered.
- UI tests that assert only that navigation did not throw.
- Finding UI components by localized text, or comparing a caption with `messages.getMessage(key)` without resolving it in the component's locale or setting the UI locale in the test.
- Leaving `@UiTest` as the system user when the behavior depends on resolving the current user from the database.
- A nested `@TestConfiguration` left out of `@SpringBootTest(classes = {...})` — its beans are silently never defined.
- Looking for dialogs or notifications by walking `UI.getCurrent().getChildren()`.
- `UiTestUtils.getComponent(view, id)` for a component inside a fragment or a `dropdownButton` item.
- Calling `click()` on a component in a non-selected `tabSheet` tab and treating the silent no-op as evidence about browser behavior.
- Asserting `isVisible()` on a grid column hidden by security.
- Browser tests for behavior that `@UiTest` or service tests can prove.
- Hardcoded sleeps when framework waits or component assertions are available.

## Special cases

### When you write a UI integration test (`@UiTest`)

```java
@UiTest
@SpringBootTest(classes = {AppApplication.class, FlowuiTestAssistConfiguration.class})
class CustomerUiTest {
    @Autowired
    private ViewNavigators viewNavigators;

    @Test
    void opensCustomerList() {
        viewNavigators.view(UiTestUtils.getCurrentView(), CustomerListView.class).navigate();
        CustomerListView view = UiTestUtils.getCurrentView();
        DataGrid<Customer> grid = UiTestUtils.getComponent(view, "customersDataGrid");
        assertThat(grid).isNotNull();
    }
}
```

- Use the project's helper for component lookup if it exists. Otherwise keep a local typed helper small and explicit.
- A wrong view id or component id is caught by the test that navigates to the view, not by `compileJava`.
- `UiTestUtils.getCurrentView()` works as the navigation origin before the test navigates anywhere: `@UiTest` opens the initial view before each test.

**Find components by id, not by localized text.** In a `@UiTest` the UI and session locale is the JVM default (`Locale.getDefault()`). `Messages` takes the locale from `CurrentAuthentication`, which has no client locale there and falls back to the first entry of `jmix.core.available-locales`. Comparing a caption with `messages.getMessage(key)` passes only where the two agree: on a developer machine, not on an `en_US` CI runner. When the test must assert localized text, resolve it with the locale the component used, or set the UI locale in the test setup.

**Authenticate as a database user when behavior depends on the current user.** By default `@UiTest` runs as the system user, which is created at startup and has no row in the application's user table. Code that resolves the current user through `DataManager` or the user repository finds no entity and can silently take a "not the current user" branch. Wrap navigation, interaction, and assertions in `runWithUser`:

```java
systemAuthenticator.runWithUser("admin", () -> {
    viewNavigators.detailView(UiTestUtils.getCurrentView(), Order.class)
            .editEntity(order)
            .navigate();
    OrderDetailView view = UiTestUtils.getCurrentView();
    JmixButton approveButton = UiTestUtils.getComponent(view, "approveButton");
    assertThat(approveButton.isVisible()).isTrue();
});
```

- Use `withUser` instead when the block returns a value.
- This is separate from testing security policies: authenticate whenever the result depends on which application user looks at the data.
- `runWithUser` in the test body does not cover code that runs before the test: `@UiTest` opens the initial/main view first, as the system user. When that view resolves the current user, or every test in the class needs the same real user, implement `UiTestAuthenticator` and pass it in `@UiTest(authenticator = ...)` so the whole class, including the initial view, runs as that user.

**List a nested `@TestConfiguration` in `classes` explicitly.** Once `@SpringBootTest(classes = {...})` names an explicit set, as `@UiTest` requires, a static nested `@TestConfiguration` is in practice not picked up automatically:

```java
@UiTest
@SpringBootTest(classes = {
        AppApplication.class,
        FlowuiTestAssistConfiguration.class,
        CustomerUiTest.MockApiConfig.class})   // ← nested config, listed EXPLICITLY
class CustomerUiTest {

    @TestConfiguration
    static class MockApiConfig { /* @Bean overrides */ }
}
```

If you leave it out, nothing fails at once: the beans are never defined, and the test runs against the real collaborator (a live HTTP call, or a `NoSuchBeanDefinition` far from the cause).

**Dialogs and notifications.** `UiTestUtils.getComponent(...)` finds only components in the view. Dialogs and notifications are not children of the `UI`: walking `UI.getCurrent().getChildren()` compiles, runs, and finds nothing (the UI's only child is the main view), and the failure looks like "the dialog never opened", which blames correct view code.

```java
DialogInfo dialog = UiTestUtils.getLastOpenedDialog();
assertThat(dialog.getText()).contains("...");
dialog.getButtons().stream()
        .filter(b -> "YES".equals(b.getText()))
        .findFirst().orElseThrow()
        .click();
```

`UiTestUtils` also has `getOpenedDialogs()`, `getLastOpenedNotification()`, `getOpenedNotifications()` and `validateView(detailView)`. Assert dialogs, notifications and validation errors through these, never by walking the tree.

These helpers read static registries (`OpenedDialogs`, `OpenedNotifications`). `JmixUiTestExtension` empties them after each test, but during a test they still hold what was opened before the action under test, by the initial view or by setup steps. Before asserting "no dialog opened" or on the last notification, clear them right before the action:

```java
openedDialogs.closeOpenedDialogs();             // @Autowired OpenedDialogs
openedNotifications.closeOpenedNotifications(); // @Autowired OpenedNotifications
approveAction.actionPerform(ordersDataGrid);
assertThat(UiTestUtils.getOpenedDialogs()).isEmpty();
```

**Data containers.** Get them through `ViewControllerUtils`, because `View.getViewData()` is protected and the compiler error does not point to the cause:

```java
CollectionContainer<Category> dc =
        ViewControllerUtils.getViewData(view).getContainer("categoriesDc");
assertThat(dc.getItems()).allMatch(Category::isApplicable);
```

**Inactive `tabSheet` tabs.** Lookup and `@ViewComponent` injection can find a component on a non-selected tab, but `JmixTabSheet` disables the content of every non-selected tab (and attaches it to the component tree only when the tab is first selected). `Button.click()` checks `isEnabled()` first, so on that content it does nothing and does not call the handler. This applies only to inactive tab content; a component that is only detached (for example built in a controller and not yet added) clicks normally. Select the tab first:

```java
JmixTabSheet tabSheet = UiTestUtils.getComponent(view, "orderTabSheet");
JmixButton approveButton = UiTestUtils.getComponent(view, "approveButton");

tabSheet.setSelectedIndex(1); // enable the tab content that contains approveButton
approveButton.click();
```

If the test targets only the server-side handler, fire the event directly and state why you bypass the disabled component:

```java
// The button is on an inactive tab; invoke the server-side handler directly.
ComponentUtil.fireEvent(approveButton, new ClickEvent<>(approveButton));
```

Firing the event directly does not prove that tab selection and the browser click work. A `click()` that does nothing on disabled content does not prove that the button is broken in a browser either. Use a browser test when that client-side path is the behavior under test.

**Components inside a fragment.** They are not found by id from the view. The fragment loader keeps a component's XML id as fragment-scoped data, not as the element id, so `UiTestUtils.getComponent(view, "ordersGrid")` and any walk comparing `Component.getId()` report "no component" for a correct descriptor. The fragment itself is a view component: get it from the view, then ask the fragment for its content:

```java
OrderListFragment fragment = UiTestUtils.getComponent(view, "orderListFragment");
DataGrid<Order> grid = (DataGrid<Order>) FragmentUtils.getComponent(fragment, "ordersGrid");
```

`FragmentUtils.findComponent(fragment, id)` is the `Optional` form; both are in `io.jmix.flowui.fragment`.

**`dropdownButton` items.** They are not view components, so `UiTestUtils.getComponent(view, itemId)` does not find them. Get the button by its component id and ask it for the item:

```java
DropdownButton createButton = UiTestUtils.getComponent(view, "createButton");
assertThat(createButton.getItem("createFromTemplate")).isNull(); // null, not an exception

ActionItem blankItem = (ActionItem) createButton.getItem("createBlank");
blankItem.getAction().actionPerform(createButton);
```

`getItems()` lists the items and skips separators.

### When a UI test checks columns or fields hidden by security

A grid column whose attribute the current role may not view is removed from the Vaadin grid, but `DataGrid` still keeps it by key: `getColumnByKey("discount")` returns the column and its `isVisible()` is `true`, so a visibility assertion reports a hidden column as shown. Assert the removal through the column's element:

```java
Grid.Column<Order> column = grid.getColumnByKey("discount");
assertThat(column == null || column.getElement().getParent() == null).isTrue();
```

A form field bound to such an attribute is hidden with `setVisible(false)`, so `assertThat(field.isVisible()).isFalse()` is correct for fields.

### When the code under test runs outside a user session

A scheduler / `@Async` / application event listener path has no authenticated user, and a test that sets up authentication hides exactly the defect worth catching. Call the entry point without authentication, and authenticate only the data setup:

```java
@Test
void generateDailyReportsRunsOnTheSchedulerThread() {
    systemAuthenticator.runWithSystem(() -> givenOrder());   // setup only
    // no authentication around the call — reproduces the scheduler thread
    reportService.generateDailyReports();
}
```

See `jmix-run-background-code` for the `@Authenticated` / `SystemAuthenticator` rules on the production side.

### When the test removes a soft-deletable entity

An entity with `@DeletedDate`/`@DeletedBy` is not removed by `dataManager.remove`: the row is only marked, stays in the store for every later run, and is visible to any query with soft deletion off. Teardown that must leave the store clean removes it hard:

```java
dataManager.save(new SaveContext()
        .setHint(PersistenceHints.SOFT_DELETION, false)
        .removing(entity));
```

### When the behavior needs a real browser

Use Masquerade/Selenide or the project's browser-test stack. Enable test ids only in a test profile, and prefer stable component ids over text selectors.
