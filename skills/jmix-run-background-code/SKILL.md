---
name: jmix-run-background-code
description: Use when writing code that runs outside a user request — a Quartz/scheduled job, an @Async method, an application-startup runner, or an integration event listener. Such threads have no authenticated user, so DataManager fails with "Authentication is not set" the first time the code actually runs. Compile, static analysis, and a green clean test all pass; only the real firing fails.
---

# Code that runs outside a user session

`DataManager` and every other secured Jmix API need an authentication in the
Spring `SecurityContext`. A UI or REST request has one (the logged-in user).
These entry points have none:

- a Quartz `Job`, a Spring `@Scheduled` method
- an `@Async` method (it runs on another thread, and the security context is
  not propagated by default)
- an `ApplicationRunner` / `CommandLineRunner` / startup `@EventListener`
  (`ApplicationStartedEvent`, `ApplicationReadyEvent`)
- a message or integration listener (JMS, Kafka, an inbound webhook processed
  off the request thread)

Without an authentication, the first `DataManager` call throws:

```
IllegalStateException: Authentication is not set. Use SystemAuthenticator in
non-user requests like schedulers or asynchronous calls.
```

No check catches this. The code compiles, passes the Jmix inspection, and
passes a green `./gradlew clean test`, because the context-load tests never
fire your scheduler. It fails the first time the job really runs, which in
production may be minutes after you report the task done.

## `@Authenticated` on the entry method (preferred)

`io.jmix.core.security.Authenticated` runs the annotated method under the
system user. Put it on the method that the background thread enters: the
Quartz job's `execute`, the `@Scheduled` method, the `@Async` method, or the
service method they call.

```java
import io.jmix.core.security.Authenticated;
import org.quartz.Job;
import org.quartz.JobExecutionContext;

public class ReportJob implements Job {

    @Autowired
    private DataManager dataManager;

    @Authenticated
    @Override
    public void execute(JobExecutionContext context) {
        List<Order> orders = dataManager.load(Order.class).all().list();
        // ...
    }
}
```

When the logic belongs in a service, annotate the service method and keep the
job a thin trigger:

```java
import io.jmix.core.security.Authenticated;
import org.springframework.stereotype.Service;

@Service
public class ReportService {

    private final DataManager dataManager;

    public ReportService(DataManager dataManager) {
        this.dataManager = dataManager;
    }

    /**
     * Runs under the system user, so it works from the scheduler thread,
     * which has no authenticated user.
     */
    @Authenticated
    public void generateDailyReports() {
        List<Order> orders = dataManager.load(Order.class)
                .query("e.status = 'NEW'")
                .list();
        // ...
    }
}
```

```java
public class ReportJob implements Job {

    @Autowired
    private ReportService reportService;

    @Override
    public void execute(JobExecutionContext context) {
        reportService.generateDailyReports();   // through the proxy → @Authenticated applies
    }
}
```

`@Authenticated` is applied by a Spring proxy, so it works on any instance that
Spring builds. A Quartz `Job` qualifies: Spring Boot's Quartz auto-configuration
installs `SpringBeanJobFactory`, so the job gets its `@Autowired` fields and is
proxied, and `@Authenticated` on `execute` takes effect.

- If the method is called from the same instance (`this.method()`), or the
  object is created outside Spring (`new ReportJob()`, a custom Quartz
  `JobFactory`), read **When the call does not go through a Spring proxy**.
- If the work cannot have its own proxied method, or must run as a specific
  user, read **When you need authentication for a block or for a named user**.

## Verify: a test that enters the path

A green `clean test` proves nothing here unless a test calls the background
entry point. Write one that calls the method the way the scheduler does,
through the bean:

```java
@SpringBootTest
class ReportJobTest {

    @Autowired
    ReportService reportService;   // the proxied bean, like the job holds

    @Test
    void generateDailyReportsRunsWithoutAuthentication() {
        // NO @ExtendWith(AuthenticatedAsAdmin.class), NO authentication set up:
        // that is the point — this reproduces the scheduler thread.
        reportService.generateDailyReports();
    }
}
```

Test authentication (`AuthenticatedAsAdmin`, `SystemAuthenticator`) around this
call hides the defect, and the test then proves nothing about the scheduler
path. If the test needs data written first, wrap only the setup in
`systemAuthenticator.runWithSystem(...)` and leave the call under test bare.
See `jmix-create-test`.

## Forbidden

- `DataManager` (or any secured API) on a scheduler / `@Async` / startup /
  message-listener thread with no `@Authenticated` method and no
  `SystemAuthenticator` wrapper.
- `@Authenticated` on a method reached by a self-call, or on a class
  instantiated outside the Spring bean factory: the proxy is not involved, so
  the annotation does nothing.
- Reporting the task done on a green `clean test` when no test enters the
  background path.
- A test that authenticates before calling the background entry point and then
  claims that path is covered.
- A test that calls the entry method on an object it created with `new` instead
  of the Spring bean: it skips the proxy and proves nothing about
  `@Authenticated`.

## Special cases

### When the call does not go through a Spring proxy

- A self-call inside one instance (`this.generateDailyReports()`) never passes
  through the proxy, so the annotation is ignored. The call must come from
  outside the instance.
- A job (or any object) built by code Spring does not own, such as
  `new ReportJob()` or a custom Quartz `JobFactory` that creates the class
  directly instead of through the bean factory, gets neither injection nor
  interception.

If you are not sure, do not reason about it: run the path with no authentication set up and see whether it
throws (see **Verify** above).

### When you need authentication for a block or for a named user

Use `io.jmix.core.security.SystemAuthenticator` when you cannot put the work in
its own proxied method, or when you need a specific user instead of the system
user. Prefer `@Authenticated` for a whole entry point; use
`SystemAuthenticator` for a narrow block inside a larger method.

```java
import io.jmix.core.security.SystemAuthenticator;

private final SystemAuthenticator authenticator;

public void onMessage(String payload) {
    authenticator.runWithSystem(() -> {
        // DataManager calls are authenticated here
    });
}
```

- `runWithSystem(Runnable)` / `withSystem(AuthenticatedOperation<T>)`: the
  system user, which bypasses security constraints. `withSystem` returns a
  value; its argument is a lambda, like `Runnable`.
- `runWithUser(String, Runnable)` / `withUser(String, AuthenticatedOperation<T>)`:
  a named user, so role policies apply as they would for that person.
