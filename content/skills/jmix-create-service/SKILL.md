---
name: jmix-create-service
description: Create Jmix 1.x service-layer business logic with DataManager, transactions, and no UI coupling.
---

# Create Service Logic

Stack: Jmix 1.x (verified on 1.4.4), Spring Boot 2.7, `javax.*`.

Use this skill when implementing business operations, calculations, or persistence workflows.

## Steps

1. Create a Spring `@Service` in the `service` package.
2. Use constructor injection.
3. Prefer `io.jmix.core.DataManager` for normal loading and saving.
4. Add `@Transactional` (`org.springframework.transaction.annotation.Transactional`) when the operation changes multiple entities or must be atomic.
5. Validate business invariants in the service before saving.
6. Return domain values or saved entities, not UI components.
7. Keep screen controllers thin: they should call services, not implement business rules.

## Service Template

```java
import io.jmix.core.DataManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.UUID;

@Service
public class AccountService {

    private final DataManager dataManager;

    public AccountService(DataManager dataManager) {
        this.dataManager = dataManager;
    }

    @Transactional
    public Account applyDelta(UUID accountId, int delta) {
        Account account = dataManager.load(Account.class)
                .id(accountId)
                .one();

        account.setBalance(account.getBalance() + delta);
        account.setLastUpdated(LocalDateTime.now());

        return dataManager.save(account);
    }
}
```

`@Transactional` works only through the Spring proxy: a call from another method of the same bean does not start a transaction.

Consume the instance RETURNED by `dataManager.save(...)`. On an update the argument is
merged, not modified: it keeps the old `version`, and saving it a second time throws
`javax.persistence.OptimisticLockException` (verified on 1.4.4: argument version 1,
returned version 2). A missing transaction boundary and reusing the stale argument are
both compile-clean defects.

## DataManager Loading

```java
Account account = dataManager.load(Account.class)
        .id(accountId)
        .one();

List<Account> positive = dataManager.load(Account.class)
        .query("select e from Account e where e.balance > :min")
        .parameter("min", 0)
        .list();
```

The short form `.query("e.balance > 0")` (where-clause only, `e` as the alias) is also accepted.

### DataManager saving

`save(entity)` re-selects the entity after persisting, so the caller gets a fresh
instance. **Jmix 1.4 has no `saveWithoutReload()`** (it appeared in later versions —
do not type it). When the caller does NOT use the result, skip the reload through
`SaveContext`:

```java
import io.jmix.core.SaveContext;

// result discarded → skip the reload
dataManager.save(new SaveContext()
        .saving(account)
        .setDiscardSaved(true));   // returns an empty EntitySet
```

Rule: use `save(entity)` when you consume the return value (you need the reloaded
state or the new version); use `SaveContext.setDiscardSaved(true)` for a
fire-and-forget persist. Several entities in one transaction:
`dataManager.save(new SaveContext().saving(a, b).removing(c))`.

## DataManager vs UnconstrainedDataManager

`DataManager` applies the current user's resource and row-level roles (Jmix 1.x
security). `io.jmix.core.UnconstrainedDataManager` (or `dataManager.unconstrained()`)
skips them. Use it only for system logic that must see everything regardless of who
triggered it, and never to "fix" an access error a user should get.

## Gotchas

- New vs detached: a null id does not mean "new" (`@JmixGeneratedValue` ids are assigned by `dataManager.create()`). Use `io.jmix.core.EntityStates#isNew(entity)`.
- `DataManager` does more than `load`/`save`: `loadValues()` / `loadValue()` for scalar/aggregate data, the Condition API (`io.jmix.core.querycondition.PropertyCondition` / `LogicalCondition`) as a JPQL alternative, pessimistic `lockMode(LockModeType)`, and hard delete of a soft-deletable entity via the hint `io.jmix.data.PersistenceHints.SOFT_DELETION` (note the package: `io.jmix.data`, not `io.jmix.core`):
    ```java
    dataManager.save(new SaveContext()
            .setHint(PersistenceHints.SOFT_DELETION, false)
            .removing(entity));
    ```
- Programmatic transactions: Spring `TransactionTemplate` (`execute` / `executeWithoutResult`); the 1.4 docs declare it as a `@Bean` built from the `PlatformTransactionManager`. An additional data store has its own transaction manager bean, `<storeName>TransactionManager`, for `@Transactional("db1TransactionManager")`.

## Called from a scheduler, `@Async`, or a listener?

A service method reached from a thread with no logged-in user needs
`@Authenticated` (or a `SystemAuthenticator` block), or its first `DataManager`
call throws `IllegalStateException: Authentication is not set`. No gate catches
this — see `jmix-run-background-code`.

## Forbidden

- Business logic in screen controllers.
- `dataManager.saveWithoutReload(...)` — it does not exist in 1.4; use `SaveContext.setDiscardSaved(true)`.
- Reusing the argument of `save()` after an update instead of the returned instance.
- UI components, `Dialogs`, `Notifications`, or screens in services.
- Constructor calls for Jmix entities — use `dataManager.create(...)` / `metadata.create(...)`.
- `EntityManager` for regular CRUD.
- `UnconstrainedDataManager` to bypass a permission the current user is supposed to lack.
- Missing transaction boundary for multi-step updates that must be atomic.

## Verify

Verify any unfamiliar Jmix symbol before typing it (`jmix-verify-api-symbol`), then run the gates after writing the service: static checks (`jmix-ide-static-analysis`) and the context-load test (`jmix-verify-bootrun`).
