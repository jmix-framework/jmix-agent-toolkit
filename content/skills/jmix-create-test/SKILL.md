---
name: jmix-create-test
description: Create or update Jmix 1.x unit, integration, Classic UI integration (jmix-ui-test-assist, @UiTest), or end-to-end tests for services, entity listeners, security behavior, screens, and persistence workflows.
---

# Create Test

Stack: Jmix 1.x (verified on 1.4.4), Spring Boot 2.7, JUnit 5, Classic UI.

Use this skill when adding or changing tests for Jmix application behavior.

## Steps

1. Choose the smallest test type that proves the behavior.
2. Use a plain JUnit 5 test for pure Java logic without Spring/Jmix services.
3. Use `@SpringBootTest` for services, DataManager persistence, entity listeners, security, and transactions.
4. Use `@UiTest` (`io.jmix.ui.testassist.junit.UiTest`) with `UiTestAssistConfiguration` (`io.jmix.ui.testassist`) for Classic UI screen/controller behavior without a browser. Add `testImplementation 'io.jmix.ui:jmix-ui-test-assist'` to `build.gradle` first — the 1.4 project template does not include it.
5. Use end-to-end browser tests only for real browser behavior, login, theme, or Vaadin client-side interactions.
6. Create test data through `DataManager.create()` and `DataManager.save()`.
7. Set authentication with the project's `AuthenticatedAsAdmin` extension (create it — see below; the 1.4 template does not generate one) or `SystemAuthenticator`.
8. Clean up created persistent data in `@AfterEach`.
9. Mock external systems at the boundary with `@MockBean` (`org.springframework.boot.test.mock.mockito.MockBean`). `@MockitoBean` does not exist on Spring Boot 2.7.
10. Run the smallest relevant Gradle test command (`./gradlew test --tests '*CustomerServiceTest'`).

Before typing any Jmix symbol you didn't copy from this project's `src` — a class, enum constant, action id, component, or event inner class — confirm it against the Jmix 1.4 docs or sources (`jmix-verify-api-symbol`). Most published Jmix test examples are Jmix 2/3 Flow UI (`FlowuiTestAssistConfiguration`, `UiTestUtils`, `ViewNavigators`): none of that exists in a Classic UI project.

## Authentication extension

The 1.4 template ships only `<Project>ApplicationTests` (`contextLoads`). Add this once
under `src/test/java/.../test_support/`:

```java
import io.jmix.core.security.SystemAuthenticator;
import org.junit.jupiter.api.extension.AfterEachCallback;
import org.junit.jupiter.api.extension.BeforeEachCallback;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.springframework.test.context.junit.jupiter.SpringExtension;

/**
 * Runs each test as the "admin" database user. Register with
 * {@code @ExtendWith(AuthenticatedAsAdmin.class)} after {@code @SpringBootTest}.
 */
public class AuthenticatedAsAdmin implements BeforeEachCallback, AfterEachCallback {

    @Override
    public void beforeEach(ExtensionContext context) {
        getSystemAuthenticator(context).begin("admin");
    }

    @Override
    public void afterEach(ExtensionContext context) {
        getSystemAuthenticator(context).end();
    }

    private SystemAuthenticator getSystemAuthenticator(ExtensionContext context) {
        return SpringExtension.getApplicationContext(context).getBean(SystemAuthenticator.class);
    }
}
```

`admin` is the user the template's Liquibase changelog creates; use another username if
the project differs.

## Unit Test Pattern

```java
class PriceCalculatorTest {
    private final PriceCalculator calculator = new PriceCalculator();

    @Test
    void appliesDiscount() {
        assertThat(calculator.applyDiscount(100, 10)).isEqualTo(90);
    }
}
```

Do not invent an unregistered anonymous or local subclass of a Jmix entity for
an in-memory fixture. The class still enters the test classpath: Jmix metadata
discovery in another test can encounter it and fail with a missing metaclass,
even when the fixture's own plain unit test passes. To exercise a missing-handler
branch, vary the injected registry or collaborator list while using an existing
entity type. If a new subtype is genuinely needed, register it through the
supported test configuration and run the full suite with a fresh context; running
only the fixture's unit test does not check metamodel discovery.

## Integration Test Pattern

```java
@SpringBootTest
@ExtendWith(AuthenticatedAsAdmin.class)
class AccountServiceTest {
    @Autowired
    private DataManager dataManager;

    @Autowired
    private AccountService accountService;

    private final List<Object> cleanup = new ArrayList<>();

    @Test
    void applyDeltaUpdatesBalance() {
        Account account = dataManager.create(Account.class);
        account.setName("acc-" + UUID.randomUUID());
        Account saved = dataManager.save(account);
        cleanup.add(saved);

        Account updated = accountService.applyDelta(saved.getId(), 10);
        assertThat(updated.getBalance()).isEqualTo(10);
    }

    @AfterEach
    void tearDown() {
        cleanup.forEach(entity -> dataManager.load(Id.of(entity)).optional().ifPresent(dataManager::remove));
        cleanup.clear();
    }
}
```

When the code under test (a service method, an entity event listener) may call `dataManager.save()` on the registered entity a second time, the reference in the cleanup list goes stale — its version lags the database — and `remove` in `@AfterEach` throws an `OptimisticLockException`. So use the id to reload-then-remove.

An exception thrown by a before-commit entity listener reaches the test as the
listener's own exception type (`assertThatThrownBy(() -> dataManager.save(entry))
.isInstanceOf(UnsupportedOperationException.class)` passes on 1.4.4).

## Security Test Pattern

```java
long visible = systemAuthenticator.withUser(
        username,
        () -> dataManager.load(Account.class).all().list().size()
);
```

Use this when the expected result depends on Jmix security policies.

Test row-level rules by loading data as the user and asserting which rows come back;
a permission API such as `io.jmix.security.constraint.SecureOperations` proves only that a policy exists.

## Classic UI Integration Test Pattern

```java
import io.jmix.ui.Screens;
import io.jmix.ui.component.GroupTable;
import io.jmix.ui.model.CollectionContainer;
import io.jmix.ui.screen.UiControllerUtils;
import io.jmix.ui.testassist.UiTestAssistConfiguration;
import io.jmix.ui.testassist.junit.UiTest;

@UiTest(authenticatedUser = "admin")
@SpringBootTest(classes = {Demo14Application.class, UiTestAssistConfiguration.class})
class UserBrowseUiTest {

    @Test
    void opensUserBrowse(Screens screens) {           // Screens is injected as a parameter
        UserBrowse browse = screens.create(UserBrowse.class);
        browse.show();

        GroupTable<User> table = (GroupTable<User>) browse.getWindow().getComponentNN("usersTable");
        CollectionContainer<User> usersDc =
                UiControllerUtils.getScreenData(browse).getContainer("usersDc");

        assertThat(table).isNotNull();
        assertThat(usersDc.getItems()).extracting(User::getUsername).contains("admin");
        assertThat(screens.getOpenedScreens().getActiveScreens()).contains(browse);
    }
}
```

What `jmix-ui-test-assist` 1.4.4 gives you (all checked in its sources):

- `@UiTest` attributes: `authenticatedUser` (default: the system user),
  `mainScreenId` (default: `jmix.ui.main-screen-id`), `screenBasePackages`.
- Before each test the extension authenticates, builds a test Vaadin session and
  `AppUI`, and opens the main screen as the root. `Screens` is the only type it resolves
  as a test-method parameter.
- There is no `UiTestUtils` or dialog/notification registry in 1.4 — use the screen
  API: `screen.getWindow().getComponentNN(id)` (finds nested components),
  `UiControllerUtils.getScreenData(screen).getContainer(id)` / `.getLoader(id)`,
  `screens.getOpenedScreens()`.

Open editors the way the application does, through `ScreenBuilders`, with the root
screen as origin:

```java
Screen root = screens.getOpenedScreens().getRootScreen();
UserEdit editor = (UserEdit) screenBuilders.editor(User.class, root)   // @Autowired ScreenBuilders
        .newEntity()
        .withScreenClass(UserEdit.class)
        .build();
editor.show();

((TextField<String>) editor.getWindow().getComponentNN("usernameField")).setValue("ui-test-user");
editor.getWindow().getActionNN("windowCommitAndClose").actionPerform(editor.getWindow());
```

Buttons can be clicked with `button.click()` (it fires the `@Subscribe` handler);
actions with `action.actionPerform(component)`.

**Open every new or changed screen in a `@UiTest`.** In 1.4.4 screen descriptors are
NOT parsed when the Spring context starts: the template's `contextLoads` stays green
with an unknown XML element in a descriptor, and only a `@UiTest` that creates and
shows the screen fails (`GuiDevelopmentException: Unknown component: ...`, verified).
The same test catches a wrong screen id, descriptor path, or component id —
`compileJava` and `contextLoads` catch none of them.

**Find components by id, not by localized text.** In a 1.4 `@UiTest` the Vaadin session
locale is fixed to `Locale.ENGLISH` by the test assist, while `Messages` takes the
locale from `CurrentAuthentication`, which has no client locale there and falls back to
the first entry of `jmix.core.available-locales`. A project whose first locale is not
English renders captions in that language while the session says English. Look
components up by id; when the test must assert localized text, resolve it with
`messages.getMessage(key, locale)` for the locale the component used.

**Authenticate as a database user when behavior depends on the current user.** By
default, `@UiTest` uses the system user. The system user has no row in the
application's user table. Code that resolves the current user through `DataManager`
or the user repository therefore finds no entity and can silently take a "not the
current user" branch. Set `@UiTest(authenticatedUser = "admin")` (or the test user):
the extension authenticates before opening the main screen, so the whole test,
including the main screen, runs as that user. For a single block inside a test, wrap
navigation, interaction, and assertions in `systemAuthenticator.runWithUser(...)` /
`withUser(...)`.

**List a nested `@TestConfiguration` in `classes` explicitly.** Once
`@SpringBootTest(classes = {...})` names an explicit set, as a `@UiTest` requires, a
static nested `@TestConfiguration` is NOT picked up (verified on 1.4.4: its bean is
absent until the class is listed). Name it yourself:

```java
@UiTest
@SpringBootTest(classes = {
        Demo14Application.class,
        UiTestAssistConfiguration.class,
        CustomerUiTest.MockApiConfig.class})   // ← nested config, listed EXPLICITLY
class CustomerUiTest {

    @TestConfiguration
    static class MockApiConfig { /* @Bean overrides */ }
}
```

Omitting it does not fail loudly: the beans simply never get defined, and the test
runs against the real collaborator (a live HTTP call, or a `NoSuchBeanDefinition`
far from the cause).

UI-scoped beans (`Fragments`, `Dialogs`, `Notifications`, `ScreenBuilders`) cannot be
`@Autowired` into a `@UiTest` class: the test class is created outside a Vaadin UI and the
context fails with `Found no valid com.vaadin.spring.internal.UIID instance!`. Take `Screens`
as a test-method parameter (as above) and reach the others through the opened screen, e.g.
`UiControllerUtils.getScreenContext(screen).getDialogs()`.

## Dialogs and notifications

They are not screen components, so `getComponent(...)` does not find them. In Classic
UI a dialog is a Vaadin `Window` added to the UI, and a notification is a Vaadin
`Notification` extension of the UI. Read them from there:

```java
import com.vaadin.ui.Notification;
import com.vaadin.ui.UI;
import com.vaadin.ui.Window;

List<String> notifications = UI.getCurrent().getExtensions().stream()
        .filter(Notification.class::isInstance)
        .map(e -> ((Notification) e).getCaption())
        .collect(Collectors.toList());

List<String> dialogs = UI.getCurrent().getWindows().stream()
        .map(Window::getCaption)
        .collect(Collectors.toList());
// e.g. table.getActionNN("remove").actionPerform(table) → dialogs contains "Confirmation"
```

**They leak into the next test.** The test assist reuses one `AppUI` for the whole test
run and never removes them (verified on 1.4.4: a notification and a confirmation dialog
from test 1 are still present in test 2). Clear them before each test, or before the
action under test:

```java
@BeforeEach
void clearUiLeftovers() {   // runs after @UiTest has set up the UI
    UI ui = UI.getCurrent();
    new ArrayList<>(ui.getWindows()).forEach(ui::removeWindow);
    new ArrayList<>(ui.getExtensions()).stream()
            .filter(Notification.class::isInstance)
            .forEach(com.vaadin.server.Extension::remove);
}
```

## Testing code that runs outside a user session

A scheduler / `@Async` / application event listener path has no authenticated user, and a test that
sets authentication up **hides** exactly the defect worth catching. Call the entry
point bare, and authenticate only the data setup:

```java
@Test
void generateDailyReportsRunsOnTheSchedulerThread() {
    systemAuthenticator.runWithSystem(() -> givenAccount());   // setup only
    // no authentication around the call — reproduces the scheduler thread
    reportService.generateDailyReports();
}
```

Do not put `@ExtendWith(AuthenticatedAsAdmin.class)` on such a class. See
`jmix-run-background-code` for the `@Authenticated` / `SystemAuthenticator` rules on
the production side and for driving a Quartz job from a test.

A Classic UI `BackgroundTask` started in a `@UiTest` runs on a worker thread as the
`@UiTest` user; `BackgroundTaskHandler.getResult()` waits for it.

## End-To-End Tests

Use the project's browser-test stack when browser verification is required (Jmix 1.4.4's
BOM has no Masquerade artifact; add whatever the project already uses). Enable
`jmix.ui.test-mode = true` only in a test profile — it adds `j-test-id` attributes to the
DOM — and prefer stable component ids over text selectors.

## Cleanup Audit

Before finishing, check:

- Every created persistent record is removed in `@AfterEach`, using the same authentication level needed for deletion.
- Cleanup reloads by id then removes instead of removing the instance that can be stale.
- A **soft-deletable** entity (one carrying `@DeletedDate`/`@DeletedBy`) is NOT removed by `dataManager.remove` — the row is only stamped, stays in the store for every later run, and stays visible to any query issued with soft deletion off. Teardown that must leave the store clean removes it hard (`io.jmix.data.PersistenceHints` in 1.4):
    ```java
    dataManager.save(new SaveContext()
            .setHint(PersistenceHints.SOFT_DELETION, false)
            .removing(entity));
    ```
- Test data has unique values to avoid collisions.
- Assertions verify persisted or visible behavior, not just absence of exceptions.
- A test that compares a stored date-time with its in-memory original (equality, "same event", `isEqual`) creates the value at the column precision — e.g. `OffsetDateTime.now().truncatedTo(ChronoUnit.MICROS)` for a PostgreSQL `timestamp`. `now()` carries nanoseconds on Linux JDKs and microseconds on macOS, and the driver rounds the value to the column on write, so a reloaded value differs from the original about half the time: green on a developer Mac, red on Linux CI.
- UI tests that depend on who is viewing the data run as a real database user (`@UiTest(authenticatedUser = ...)` or `runWithUser`).
- UI tests that assert dialogs or notifications clear the leftovers first.
- Every screen added or changed in the task is opened by at least one `@UiTest` (`contextLoads` does not parse descriptors).
- The test command can run one class or method without running the full suite.
- No `@Transactional` on the test class or methods — it rolls back the writes that `@AfterEach` cleanup and the twice-back-to-back run depend on.
- Run the single class twice back-to-back — a second green run proves no leaked rows or cross-test data dependence that one pass hides.
- `@AfterEach` deletions run in FK-safe order: child rows (holding a `@ManyToOne`/`@JoinColumn` to another cleaned-up entity) before the parents they reference. Re-check this whenever a new FK is added to an entity already covered by an existing cleanup block — a previously-safe order can silently become unsafe and throw a constraint violation in teardown, which JUnit reports against the test that triggered it rather than the cleanup, so it first reads as a test bug rather than an ordering one.
- **The tests write to the development database.** The 1.4 template has no test datasource: `@SpringBootTest` uses `main.datasource.url` from `src/main/resources/application.properties`, by default the HSQLDB **file** `jdbc:hsqldb:file:.jmix/hsqldb/<project>` that `bootRun` also uses. Rows a test leaves behind survive every later run and appear in the running app. So `@AfterEach` cleanup is mandatory even for a test that only reads setup data, and a test that calls the same method twice to prove idempotency must not assume a fresh precondition — set up explicitly the precondition the code under test actually checks.

## Forbidden

- `@Transactional` on test classes/methods — it rolls back writes, so `@AfterEach` cleanup of committed entities and running the test twice back-to-back both stop working.
- `@MockitoBean` (not on Spring Boot 2.7) — use `@MockBean`.
- Flow UI test API in a Classic UI project: `FlowuiTestAssistConfiguration`, `UiTestUtils`, `ViewNavigators`, `io.jmix.flowui.*`.
- `new Entity()` or constructor-created Jmix entities in persistence tests.
- Tests that depend on data left by previous tests.
- Cleanup only at the end of the test method.
- UI tests that assert only that opening a screen did not throw.
- Asserting "no dialog/notification" without clearing the ones earlier tests left on the shared UI.
- Leaving `@UiTest` as the system user when the behavior depends on resolving the current user from the database.
- Browser tests for behavior that `@UiTest` or service tests can prove.
- Hardcoded sleeps when framework waits or component assertions are available.
- `@WithUserDetails` for Jmix security tests when `SystemAuthenticator` or the project auth extension is available.
- A nested `@TestConfiguration` left out of `@SpringBootTest(classes = {...})` — its beans are silently never defined.
- `spring.main.allow-bean-definition-overriding=true` to replace a bean for one test — use `@MockBean` or a distinct `@Primary` bean instead.
- Authenticating before calling a scheduler/`@Async` entry point and then claiming that path is covered.
