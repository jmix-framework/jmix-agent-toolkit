---
name: jmix-run-background-code
description: "Use when writing Jmix 1.x code that runs outside a user request: a Quartz job, a Spring @Scheduled method, an @Async method, an application-startup runner, an integration listener, or a Classic UI BackgroundTask. Server-side threads have no authenticated user, so DataManager fails with \"Authentication is not set\" the first time the code actually runs. Compile, static analysis, and a green clean test all pass; only the real firing fails."
---

# Code that runs outside a user session

Stack: Jmix 1.x (verified on 1.4.4), Spring Boot 2.7, Classic UI.

`DataManager` and every other secured Jmix API require an authentication in the
Spring `SecurityContext`. A normal UI or REST request has one — the logged-in
user. These entry points do NOT:

- a Quartz `Job`, a Spring `@Scheduled` method
- an `@Async` method — it runs on a different thread, and the security context is
  not propagated (verified on 1.4.4: an `@Async` method fails even when its caller
  is authenticated)
- an `ApplicationRunner` / `CommandLineRunner` / startup `@EventListener`
  (`ApplicationStartedEvent`, `ApplicationReadyEvent`)
- a message/integration listener (JMS, Kafka, an inbound webhook processed off
  the request thread)

Without an authentication, the first `DataManager` call throws:

```
IllegalStateException: Authentication is not set. Use SystemAuthenticator in
non-user requests like schedulers or asynchronous calls.
```

**No gate catches this.** It compiles and passes a green `./gradlew clean test` — the
context-load tests never fire your scheduler. It fails the first time the job actually
runs, which in production may be minutes after you declared the task done.

The exception is the Classic UI `BackgroundTask` — see the last section: it runs as the
user who started it.

## Pattern 1 — `@Authenticated` on the entry method (preferred)

`io.jmix.core.security.Authenticated` runs the annotated method under the **system**
user (the aspect calls `SystemAuthenticator.begin()` / `end()` around it). Put it on
the method that the background thread ENTERS — the Quartz job's `execute`, the
`@Scheduled` method, the `@Async` method, or the service method they call.

### Quartz

In 1.x use the Quartz add-on: `implementation 'io.jmix.quartz:jmix-quartz-starter'`
(version from the Jmix BOM; 1.4.4 ships `jmix-quartz` and `jmix-quartz-starter` only,
with Classic UI screens under *Administration → Quartz jobs* and its own Liquibase
changelog for the JDBC job store). Without the add-on the docs describe plain
`spring-boot-starter-quartz` with `spring.quartz.job-store-type = jdbc`.

```java
import io.jmix.core.DataManager;
import io.jmix.core.security.Authenticated;
import org.quartz.Job;
import org.quartz.JobExecutionContext;
import org.springframework.beans.factory.annotation.Autowired;

import java.util.List;

public class ReportJob implements Job {

    @Autowired
    private DataManager dataManager;

    @Authenticated
    @Override
    public void execute(JobExecutionContext context) {
        List<Account> accounts = dataManager.load(Account.class).all().list();
        // ...
    }
}
```

Verified on 1.4.4 with the add-on: this job runs; the same job without `@Authenticated`
fails with "Authentication is not set".

When the logic belongs in a service, annotate the service method instead and let
the job be a thin trigger:

```java
import io.jmix.core.DataManager;
import io.jmix.core.security.Authenticated;
import org.springframework.stereotype.Service;

import java.util.List;

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
    public int generateDailyReports() {
        List<Account> accounts = dataManager.load(Account.class)
                .query("e.balance > 0")
                .list();
        // ...
        return accounts.size();
    }
}
```

### Spring `@Scheduled`

Jmix 1.4 does **not** enable scheduling for you: without `@EnableScheduling` a
`@Scheduled` method never fires (verified on 1.4.4 — zero runs) and nothing reports it.
Add it once on a `@Configuration` class (and `@EnableAsync` if you use `@Async`):

```java
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.annotation.EnableScheduling;

@Configuration
@EnableScheduling
@EnableAsync
public class SchedulingConfig {
}
```

```java
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class ReportScheduler {

    private final ReportService reportService;

    public ReportScheduler(ReportService reportService) {
        this.reportService = reportService;
    }

    @Scheduled(fixedDelay = 60_000)
    public void runDailyReports() {
        reportService.generateDailyReports();   // through the proxy → @Authenticated applies
    }
}
```

For `@Async`, `@Async` and `@Authenticated` on the same method work together: the
authentication is set on the async thread (verified on 1.4.4).

### Where the annotation applies — and where it does not

`@Authenticated` is applied by a Spring proxy, so it works wherever Spring builds
the instance. **A Quartz `Job` qualifies:** Spring Boot's Quartz auto-configuration
uses Spring's `SpringBeanJobFactory`, so the job gets its `@Autowired` fields AND
gets proxied, and `@Authenticated` directly on `execute` takes effect.

It is NOT applied when the proxy is out of the picture:

- A **self-call** inside one instance (`this.generateDailyReports()`) never passes
  through the proxy, so the annotation is ignored — verified on 1.4.4: a bean method
  that calls its own `@Authenticated` method fails with "Authentication is not set".
  The call must arrive from outside the instance.
- A job (or any object) built by code Spring does not own — `new ReportJob()`, or a
  custom Quartz `JobFactory` that instantiates the class directly instead of going
  through the bean factory. Then neither injection nor interception happens.

When in doubt, do not reason about it — run the path with no authentication set up
and see whether it throws (see "Verify it" below).

## Pattern 2 — `SystemAuthenticator` for a block

Use `io.jmix.core.security.SystemAuthenticator` when you cannot put the work in
its own proxied method, or when you need a specific user rather than the system
user:

```java
import io.jmix.core.DataManager;
import io.jmix.core.security.SystemAuthenticator;
import org.springframework.stereotype.Component;

@Component
public class MessageHandler {

    private final SystemAuthenticator authenticator;
    private final DataManager dataManager;

    public MessageHandler(SystemAuthenticator authenticator, DataManager dataManager) {
        this.authenticator = authenticator;
        this.dataManager = dataManager;
    }

    public void onMessage(String payload) {
        authenticator.runWithSystem(() -> {
            // DataManager calls are authenticated here
        });
    }

    public long countAs(String username) {
        return authenticator.withUser(username,
                () -> dataManager.load(Account.class).all().list().size());
    }
}
```

- `runWithSystem(Runnable)` / `withSystem(AuthenticatedOperation<T>)` — the system
  user, which bypasses security constraints. The `withSystem` variant returns a
  value; its argument is a lambda, same as `Runnable`.
- `runWithUser(String, Runnable)` / `withUser(String, AuthenticatedOperation<T>)` —
  a named user, so role policies apply as they would for that person.
- `begin()` / `begin(login)` / `end()` — the low-level pair; `end()` must be in a
  `finally` block.

Prefer `@Authenticated` for a whole entry point; use `SystemAuthenticator` for a
narrow block inside a larger method.

`UnconstrainedDataManager` also works on an unauthenticated thread (the 1.4 Quartz
docs mention it; verified on 1.4.4 for load and save), but audit fields such as
`@CreatedBy` are then left `null`, and any other secured API you call still needs an
authentication. Prefer `@Authenticated`.

## Classic UI: `BackgroundTask`

For long work started from a screen, use `io.jmix.ui.executor.BackgroundTask` with the
`BackgroundWorker` bean. Its `run()` executes on a separate thread **as the user who
started the task** — `WebBackgroundWorker` copies the UI thread's authentication into
the task thread (verified on 1.4.4: `currentAuthentication.getUser()` in `run()`
returns the screen user), so no `@Authenticated` is needed there.

```java
import io.jmix.ui.executor.BackgroundTask;
import io.jmix.ui.executor.BackgroundTaskHandler;
import io.jmix.ui.executor.BackgroundWorker;
import io.jmix.ui.executor.TaskLifeCycle;

@Autowired
private BackgroundWorker backgroundWorker;

@Subscribe("recalculateBtn")
public void onRecalculateBtnClick(Button.ClickEvent event) {
    BackgroundTask<Integer, Integer> task = new BackgroundTask<Integer, Integer>(60, TimeUnit.SECONDS, this) {
        @Override
        public Integer run(TaskLifeCycle<Integer> taskLifeCycle) throws Exception {
            // background thread: services / DataManager only, no UI components
            return reportService.generateDailyReports();
        }

        @Override
        public void done(Integer result) {
            // UI thread: safe to update components and show notifications
        }
    };
    BackgroundTaskHandler<Integer> handler = backgroundWorker.handle(task);
    handler.execute();
}
```

- Do not read or change UI components or data containers in `run()`: it is not the UI
  thread (`IllegalConcurrentAccessException`). Use `done()`, `progress()`
  (fed by `taskLifeCycle.publish(...)`), `canceled()`, `handleException()`; values from
  components go in through `getParams()`.
- Passing the screen (`this`) ties the task to it: closing the screen interrupts the
  task. Check `taskLifeCycle.isCancelled()` / `isInterrupted()` in long loops.
- `dialogs.createBackgroundWorkDialog(this, task)` shows a modal progress dialog with
  optional Cancel (progress type `T` must be a `Number`).
- This is Classic UI (`io.jmix.ui.executor`). Do not use Flow UI (`io.jmix.flowui.*`)
  background-task classes in a 1.x Classic UI project.

## Verify it — a test that actually enters the path

A green `clean test` proves nothing here unless a test calls the background entry
point. Write one that invokes the method the same way the scheduler does, through
the bean:

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

Setting up test authentication (`AuthenticatedAsAdmin`, `SystemAuthenticator`)
around this call HIDES the defect — the test then proves nothing about the
scheduler path. If the test needs data written first, wrap only the **setup** in
`systemAuthenticator.runWithSystem(...)` and leave the call under test bare. See
`jmix-create-test`.

To prove a Quartz job itself, schedule it from the test with the injected
`org.quartz.Scheduler` (`JobBuilder.newJob(ReportJob.class)` +
`TriggerBuilder.newTrigger().startNow()`) and wait on a latch the job counts down;
give the job a unique identity, because the add-on's JDBC store persists jobs.

## Forbidden

- `DataManager` (or any secured API) on a scheduler / `@Async` / startup /
  message-listener thread with no `@Authenticated` method and no
  `SystemAuthenticator` wrapper.
- `@Scheduled` methods in a project with no `@EnableScheduling` — they silently never
  run. Likewise `@Async` needs `@EnableAsync`; no Jmix 1.4.4 module enables either.
- `@Authenticated` on a method reached by a self-call, or on a class instantiated
  outside the Spring bean factory — the proxy is not involved, so the annotation
  does nothing.
- Touching UI components or data containers inside `BackgroundTask.run()`.
- Declaring the task done on a green `clean test` when no test enters the
  background path.
- A test that authenticates before calling the background entry point and then
  claims that path is covered.
