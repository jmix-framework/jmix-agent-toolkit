---
name: jmix-verify-bootrun
description: Gate 2 (mandatory) — verify the Spring/Jmix 1.x context loads via a TERMINATING `gradle clean test` on JDK 11/17, never a long-running bootRun; in 1.x it does not open screens, so add a @UiTest that opens each new screen. Gate 3 — walk the Classic UI screens you created (hash URLs, login screen, menu) with a browser tool to catch render-time defects. A green compile/clean test is NOT proof a screen opens.
---

# Gate 2 (context load) + Gate 3 (render walk)

Stack: Jmix 1.x (verified on 1.4.4): Java 11/17, Spring Boot 2.7, Gradle 7.5 with the
`io.jmix` plugin, Classic UI (Vaadin 8).

## When to use

After writing your Jmix artifacts (entities, screens, services, roles, …):
- **Gate 2 (mandatory):** confirm the Spring/Jmix context loads cleanly.
- **Screen-opening tests / Gate 3:** confirm each screen you created actually opens.

These run AFTER static analysis (`jmix-ide-static-analysis`). Treat inspection
findings as WARNINGS to resolve first — and remember an EMPTY inspection result you
did not confirm is false-clean, not a pass.

## JDK: 11 or 17, never 21

Run every Gradle command of a 1.x project with `JAVA_HOME` pointing to JDK 11 or 17:

```bash
JAVA_HOME=/path/to/jdk-17 ./gradlew --no-daemon clean test
```

Gradle 7.5 does not support JDK 21. On 1.4.4 with the system JDK 21 the wrapper even
starts, and then the build is broken in a misleading way: `compileJava` "succeeds" while
the entity enhancer logs `Unsupported class file major version 65` for every class,
and every test fails at context start with `BeanDefinitionStoreException ... Caused by:
IllegalArgumentException at ClassReader` (Spring 5.3 cannot read Java 21 class
files). That is the JDK, not your code — switch `JAVA_HOME` and run `clean test` again.
Check with `"$JAVA_HOME/bin/java" -version` before the first build of the session.

## Gate 2 — `clean test` (NEVER bootRun)

Before rebuilding, check whether an existing application process consumes this
checkout's output JARs or its HSQLDB files. Coordinate an approved stop/rebuild/restart
with its owner, or use isolated build outputs and a separate test datasource. Do not
overwrite a running process's archives blindly.

```bash
./gradlew --no-daemon clean test
```

It boots the Spring/Jmix context, runs the project's tests, and EXITS. Confirm
`BUILD SUCCESSFUL` and no failed tests. Also confirm tests actually ran: `Tests run: 0`
(or no test task at all) means the context was never booted and Gate 2 did NOT pass.
With `-q` Gradle prints nothing on success; read the counts from
`build/test-results/test/*.xml` (`<testsuite ... tests="N" failures="0" errors="0">`).

**NEVER use `./gradlew bootRun` (or any non-terminating server start) as the
Gate-2 check.** bootRun does not exit — it hangs your turn and leaves the HTTP port
locked by a zombie process.

### The generated test writes into the development database

The 1.4 template's `<App>ApplicationTests` is a bare `@SpringBootTest` with no test
properties, so it runs against `main.datasource.url` from `application.properties` —
the developer's file HSQLDB under `.jmix/hsqldb/`. Liquibase migrates it and any test
data lands there. For tests you add, override the datasource on the test class:

```java
@SpringBootTest(properties = "main.datasource.url=jdbc:hsqldb:mem:testdb")
```

### Gate 2 does NOT open screens in 1.x

In Jmix 1.4.4 a context-load test does not parse screen descriptors or wire
controllers. Verified: a screen whose descriptor contains an unknown element and whose
controller `@Autowired`s a non-existent component passes `contextLoads()`; it fails only
when opened, with `GuiDevelopmentException: Unknown component: ...` or
`DevelopmentException: Unable to find an instance of type ... named ...`. So for every
screen you created or changed, add a headless test that OPENS it (see
`jmix-create-test`):

```groovy
// build.gradle
testImplementation 'io.jmix.ui:jmix-ui-test-assist'
```

```java
import io.jmix.ui.Screens;
import io.jmix.ui.testassist.UiTestAssistConfiguration;
import io.jmix.ui.testassist.junit.UiTest;

@UiTest
@SpringBootTest(classes = {DemoApplication.class, UiTestAssistConfiguration.class},
        properties = "main.datasource.url=jdbc:hsqldb:mem:uitest")
class TicketScreensTest {
    @Test
    void browseOpens(Screens screens) {
        screens.create(TicketBrowse.class).show();
    }
}
```

`@UiTest` authenticates as the system user by default (`authenticatedUser = "..."` for
a real user, who must already exist) and opens the main screen first. An unresolved
`msg://` key still passes such a test: it renders as the bare key without an exception.

### When the first Gate 2 failure hides the real cause

The console tail may show only a wrapper exception. Read the generated JUnit XML
before diagnosing:

```bash
rg -n -C 3 "Caused by|message=" build/test-results/test/*.xml
```

If the test suite passed before your changes and a test is now RED, assume you broke
it and fix it to green. Do not call that failure "pre-existing".

Common causes when a test goes red after your change:

- **`MetaClass not found for class X`** → the entity is missing `@JmixEntity`, its
  package is outside the application scan root, or it was not enhanced: run a full
  Gradle build (`clean test`), not a bare IDE compile, on JDK 11/17.
- **Liquibase error at context start** → a changelog does not match the entity or
  breaks on HSQLDB (see `jmix-create-liquibase-changelog`).
- **`ConstraintViolationException` on save** → a `@NotNull` persistent field has
  no value on the `DataManager` path (see `jmix-create-entity`).
- **`GuiDevelopmentException` / `DevelopmentException` in a `@UiTest`** → a descriptor
  or controller wiring defect of the screen it opened (see `jmix-ide-static-analysis`).

A test that goes red and you cannot explain is a blocker, never a footnote in your
"done" summary.

A green Gate 2 is necessary but NOT sufficient: the context-load test does not open
your screens, exercise your roles, or fire code that only runs outside a user request
(see `jmix-run-background-code`). The rule behind it: a defect survives every gate
when nothing enters its code path. So when you add a path that nothing yet calls, ADD
THE CALLER — a test or a render walk — or report it as unverified. Never write "all
gates passed" for a path no gate entered.

## Gate 3 — render walk (REQUIRED for every screen/role you created or changed)

Per such screen, pick ONE:
- a browser/UI-automation tool is connected → render-walk it (below); or
- no browser tool → the `@UiTest` above that opens the screen, plus role checks
  through `AccessManager` (see `jmix-create-resource-role`).

Do not write "no browser tool" without checking the connected tools. Only if a screen
can be reached by NEITHER, report `render NOT verified: <screen>`, never "all gates
passed".

**Readiness signal.** Jmix 1.x projects do not include Spring Boot Actuator. Poll the
root URL until it answers 200, or wait for `Started <App>Application in` in the log:

```bash
curl --retry-connrefused --retry 60 --retry-delay 2 -s -o /dev/null -w '%{http_code}\n' \
     -m 5 http://localhost:8080/
```

If you add Actuator instead (`spring-boot-starter-actuator`,
`management.endpoints.web.exposure.include=health`), poll `/actuator/health`.

**Before you start it — decide which database the walk writes into.** A walk of a
data-driven screen usually has to CREATE data, and there is no undo step. The configured
datasource (`.jmix/hsqldb/<name>`) is frequently the developer's own working dataset:

- **A throwaway datasource — the default choice.** Select it on the run command line so
  the properties file is never touched:
  ```bash
  JAVA_HOME=/path/to/jdk-17 nohup ./gradlew --no-daemon bootRun \
        --args="--server.port=8093 --jmix.ui.test-mode=true --main.datasource.url=jdbc:hsqldb:file:/tmp/renderwalk/db" \
        > /tmp/jmix_app.log 2>&1 &
  ```
  Do NOT edit `application.properties` to point it elsewhere: that file is tracked.
  Pick a free port (`ss -ltn | grep ':8080 '`); the IDE often already runs an app on 8080.
- **The configured development database — only for a read-only walk.**

The fixture data is a side effect you own. Report what you created and where it landed.

**If the application is already running** — the owner started it, possibly on a
non-default port — take that base URL and port as given. Confirm it loads the verified
artifacts before the walk. If a restart is needed, obtain the owner's approval; without
it report the new build's browser check as unverified. Never start a second instance on
their port or shut theirs down without approval. Note in the report that the app was
not started by the gate. The numbered steps below are for when you start and own the
process.

1. Start the app in the BACKGROUND (command above), capturing its log.
2. Poll readiness (above). If it never becomes ready, tail the log, skip the walk,
   and shut the process down.
3. Walk the screens (next section). When you created roles, log in through the login
   screen as one user of each role, not only as `admin`: `admin` holds
   `system-full-access`, which hides missing login, screen and menu policies. A user
   without `ui-minimal` / `ui.loginToUi` gets an "Access denied" notification on the
   login screen. If the application accepts file uploads, upload a real file through
   the browser and confirm it can be read back.
4. **Shut the background app down** when finished: kill the Java process that listens
   on your port and the Gradle process you started, BY PID (`ss -ltnp | grep ':8093 '`
   for the Java PID). Never `pkill` by a name pattern such as `Application` or
   `bootRun`: other agents and the IDE run processes with the same names. Leave the port
   free, and state which database the walk ran against and what data it created.

### Classic UI URLs, login and navigation (verified on 1.4.4)

- The UI lives at the context root; the navigation state is the URL **fragment**:
  `http://localhost:8080/#login` (login screen, `@Route(path = "login", root = true)`),
  `#main` after login.
- A screen with `@Route("tickets")` opens at `http://localhost:8080/#main/tickets` once
  logged in. The app rewrites it to `#main/<n>/tickets`: `<n>` is a state mark used
  internally by navigation, not something to construct. An editor with
  `@Route(value = "tickets/edit", parentPrefix = "tickets")` shows
  `#main/<n>/tickets/edit` for a new entity and `...?id=<id>` for an existing one
  (UUIDs Base32-encoded). Screens without `@Route` are not URL-addressable: open them
  from the menu or from another screen.
- Opening a screen by URL or menu goes through the screen policy: a non-permitted screen
  shows "Access denied" instead.
- Start with `--jmix.ui.test-mode=true` (property `jmix.ui.test-mode`): components then
  carry a `j-test-id` attribute equal to their XML id — `usernameField`,
  `passwordField` on the generated login screen, `ticketsTable`, `createBtn` — and side
  menu items carry their menu item id (`Ticket.browse`, group `helpdesk`). Without it,
  locate elements by visible text.
- Login: fill `[j-test-id="usernameField"]` and `[j-test-id="passwordField"]`, press
  `Enter` (or click the login button), then wait until `location.hash` starts with
  `#main`. The template's default credentials are `admin` / `admin`.

### Driving a Classic UI (Vaadin 8)

The page is a Vaadin 8 client: GWT widgets with `v-*` CSS classes, rendered by a
client that keeps working after the HTTP response is done (not `vaadin-*` web
components as in Flow UI):

- **Wait for the client to render before you look.** The first snapshot after
  navigation is routinely blank; wait for a selector you expect.
- **Refs go stale after every action.** Retake the snapshot immediately before each
  interaction rather than reusing refs captured earlier in the walk.
- **Prefer `j-test-id` selectors** (test mode) over role/name locators.
- **A disabled action is usually a precondition, not a defect.** Jmix list actions
  enable on selection and permissions — satisfy what this one waits for before
  reporting it broken.
- Drive the walk **only through real input events** — a genuine click, real typing,
  `Enter`. Never set a field's value from the page or console: the server holds the
  component state, so a scripted mutation never reaches it and can desync the session,
  silently invalidating the gate. Reading the DOM to assert what rendered is fine;
  mutating it is not.

### When the browser sees older resources than the tests

If a fresh-context test passes but the running screen cannot find a component or
`@Subscribe` target, compare the source, the built resource and the effective runtime
resource. Jmix 1.x loads overrides from `jmix.core.conf-dir` (default
`${user.dir}/.jmix/conf`) before the classpath, including screen descriptors and
hot-deployed controller classes. Remove the entire `.jmix/conf/` directory if it
exists, before changing valid code. Archive-read failures after a rebuild need the
approved restart above.

Remove `.jmix/conf/` also after every walk during which code was edited while the app
was running, and before the next Gate 2 run: `clean test` does not clean `.jmix/`, and
Jmix then loads the stale class with its own class loader. The symptom is a
`ClassCastException` between two classes with the same name in every test that opens
the screen.

### File uploads in a non-root container

If the deliverable includes a container image, a local upload does not verify the
container filesystem permissions. Jmix 1.x writes temporary files to
`jmix.core.temp-dir` (default `${user.dir}/.jmix/temp`) and the local file storage to
`jmix.core.work-dir/filestorage` (default `${user.dir}/.jmix/work/filestorage`). For an
image that runs as a non-root `app` user with `/app` as its working directory:

```dockerfile
RUN mkdir -p /app/.jmix/temp /app/.jmix/work && chown -R app:app /app/.jmix
```

## Honest scope — Gate 3 is a render gate

A browser walk catches the gross exceptions a user would hit, but a `@UiTest`
exercises a different, headless code path (`jmix-ui-test-assist`). A defect can pass
in the browser and still fail a test, and the reverse. Never let a green render walk
override the mechanical checks.
