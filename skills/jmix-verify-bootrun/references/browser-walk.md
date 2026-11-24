# Gate 3 — walk views in a browser

Part of `jmix-verify-bootrun`. Read this before you walk a view with a browser tool.

**Actuator.** Readiness is checked on `/actuator/health`, and Jmix projects do
not include Actuator by default. Add it:

```groovy
// build.gradle
implementation 'org.springframework.boot:spring-boot-starter-actuator'
```

```properties
# application.properties
management.endpoints.web.exposure.include=health
```

If you cannot add it, use the `@UiTest` path, or wait for
`Started <App>Application in ...` in the log.

**Database.** A walk of a data-driven view usually has to create data, and
nothing removes it afterwards. The configured development database is often the
developer's own data. By default, use a throwaway datasource set on the command
line. Use the configured database only for a walk that creates nothing.

These steps are for an application you start yourself.

1. Start the application in the background. Leave out `--args=...` only for a
   walk that creates nothing:
   ```bash
   nohup ./gradlew --no-daemon bootRun \
         --args="--main.datasource.url=jdbc:hsqldb:file:/tmp/renderwalk" > /tmp/jmix_app.log 2>&1 &
   ```
2. Wait until it is ready:
   ```bash
   curl --retry-connrefused --retry 40 --retry-delay 2 -sf -m 5 \
        http://localhost:8080/actuator/health && echo READY
   ```
   If it never becomes ready, read the log and stop the process. Then use the
   `@UiTest` path, or report `render NOT verified: <view>`.
3. Open each view you created, click each button and action, fill each field,
   and confirm there is no error overlay or server exception. When you created
   roles, log in through the login form as a user of each role, not only as
   `admin`: `admin` usually
   has `system-full-access`, which hides missing login, view, and menu policies.
   If the application accepts file uploads, upload a real file through the
   browser, confirm that the UI reports success, and confirm that the file can
   be opened or read back.
4. Stop the application (`kill` the PID; if the port stays held, kill the
   process that holds it). Report which database the walk used and what data
   it created there.
5. If you edited code while the application was running, delete `.jmix/conf/`
   before the next Gate 2 run.

A Jmix UI is built from `vaadin-*` web components and does not behave like a
plain HTML page:

- Use only real input: clicks, typing, `Enter`. A value set by a script never
  reaches the server and can break the session; the application then returns to
  the login view with nothing in the browser console. Reading the DOM is fine.
- The first snapshot after navigation is often blank; retry until the content
  is there before reporting a render failure.
- Take a new snapshot before each interaction; references go stale after every
  action.
- Role/name locators often miss `vaadin-*` components; use a reference from the
  current snapshot, or a DOM query by tag name and visible text.
- A disabled action usually waits for a precondition; satisfy it before
  reporting a defect.
