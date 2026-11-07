---
name: jmix-add-entity-event-listener
description: Add Jmix 1.x entity lifecycle event listeners (EntitySavingEvent, EntityLoadingEvent, EntityChangedEvent before or after commit) to perform additional actions with saved or loaded entities.
---

# Add Entity Event Listener

Stack: Jmix 1.x (verified on 1.4.4), Spring Boot 2.7, EclipseLink, `javax.*`.

Use this skill when business logic must react to entity save, change, delete, or load events.

## Steps

1. Create a Spring `@Component` listener in `service` or `listener`.
2. Use `org.springframework.context.event.EventListener`.
3. Use exact Jmix imports (all three live in `io.jmix.core.event` in 1.4):
   - `io.jmix.core.event.EntityChangedEvent`
   - `io.jmix.core.event.EntityLoadingEvent`
   - `io.jmix.core.event.EntitySavingEvent`
4. For created entities, load by `event.getEntityId()` when related data is needed.
5. If you specify a custom fetch plan, include every scalar and reference property read later (see `jmix-configure-fetch-plan`).
6. For deleted entities, do not load `event.getEntityId()`; use old values or old reference ids from `event.getChanges()`.
7. Use `EntitySavingEvent` for defaults or transformations that must happen before data is saved; `event.isNewEntity()` tells an insert from an update. A required persistent default still belongs at the entity layer (see `jmix-create-entity`).
8. Use `EntityLoadingEvent` for initializing non-persistent attributes from already loaded local persistent state, and guard every read with `EntityStates.isLoaded` (see "EntityLoadingEvent runs for every fetch plan").
9. Use a before-commit `@EventListener` path for validation that must reject the current save/remove operation.
10. Put multi-entity changes in a transactional service method when atomicity matters.
11. Reject unsupported updates/deletes inside the event path before treating work as complete.
12. Search the changed code for `@TransactionalEventListener`; if the listener performs validation, rejects updates/deletes, or sets required defaults, replace it with `@EventListener` plus `EntitySavingEvent`/`EntityChangedEvent` or another before-commit path. Decide by the direction of failure — see "Event Timing".
13. Add tests or at least compile/startup validation for the event listener (see `jmix-create-test`).

## EntityChangedEvent

### Listener Template

```java
import io.jmix.core.DataManager;
import io.jmix.core.FetchPlan;
import io.jmix.core.event.EntityChangedEvent;
import io.jmix.core.event.EntityLoadingEvent;
import io.jmix.core.event.EntitySavingEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;

@Component
public class LedgerEntryEventListener {

    private final DataManager dataManager;
    private final LedgerService ledgerService;

    public LedgerEntryEventListener(DataManager dataManager,
                                    LedgerService ledgerService) {
        this.dataManager = dataManager;
        this.ledgerService = ledgerService;
    }

    @EventListener
    public void onLedgerEntryChanged(EntityChangedEvent<LedgerEntry> event) {
        if (event.getType() == EntityChangedEvent.Type.CREATED) {
            LedgerEntry entry = dataManager.load(LedgerEntry.class)
                    .id(event.getEntityId())
                    .fetchPlan(fp -> fp.addFetchPlan(FetchPlan.BASE)
                            .add("account", FetchPlan.BASE))
                    .one();
            ledgerService.apply(entry.getAccount().getId(), entry.getAmount(), entry.getType());
            return;
        }
        if (event.getType() == EntityChangedEvent.Type.UPDATED
                && event.getChanges().isChanged("amount")) {
            throw new UnsupportedOperationException("This record cannot be updated");
        }
    }

    @EventListener
    public void onLedgerEntrySaving(EntitySavingEvent<LedgerEntry> event) {
        LedgerEntry entry = event.getEntity();
        if (event.isNewEntity() && entry.getCreatedDate() == null) {
            entry.setCreatedDate(LocalDateTime.now());
        }
    }

    @EventListener
    public void onLedgerEntryLoading(EntityLoadingEvent<LedgerEntry> event) {
        LedgerEntry entry = event.getEntity();
        entry.setDisplayLabel(entry.getNumber() + " / " + entry.getType());
    }
}
```

An exception thrown from a before-commit `EntityChangedEvent` listener propagates out of
`dataManager.save()` / `remove()` and rolls the whole transaction back: the row is not
changed (verified on 1.4.4 for a rejected update and a rejected delete).

### Fetch Plan Safety

For non-deleted events, the loaded entity should contain every property the listener reads. The default plan is `_base` (local attributes only), so a reference read after a plain load is lazy-loaded outside the save path — but code that may run inside one (see "Reading a reference you nevertheless need") must load it explicitly:

```java
LedgerEntry entry = dataManager.load(LedgerEntry.class)
        .id(event.getEntityId())
        .fetchPlan(fp -> fp.addFetchPlan(FetchPlan.BASE)
                .add("account", FetchPlan.BASE))
        .one();

ledgerService.apply(entry.getAccount().getId(), entry.getAmount(), entry.getType());
```

After writing the listener, scan the method: every `entry.getX()` used after loading must be available in the fetch plan.

### Event Timing

`EntityChangedEvent` is delivered in two ways:

- `@EventListener` — inside the current transaction, after the SQL flush and before
  the commit. Data you change here is committed together with the original change;
  an exception rolls everything back.
- `@TransactionalEventListener` (Spring, default phase `AFTER_COMMIT`) — after the
  commit. Exceptions thrown here are **neither propagated to the caller nor logged**
  (verified on 1.4.4: the `save()` returns normally, nothing in the log), so wrap the
  body in try/catch and log yourself.

Use normal Spring `@EventListener` for logic that must affect the current save/remove operation:

- required default values;
- rejecting unsupported updates or deletes;
- synchronous changes to related persistent state;
- validation whose exception must propagate to `DataManager.save()` or `DataManager.remove()`.

`@TransactionalEventListener` is for after-transaction reactions such as notifications or integration events. Do not use it when failure must roll back or reject the current persistence operation.

In an after-commit listener the original transaction is finished, so any data access must start a new one: `dataManager.load(...).joinTransaction(false)` for loading, `new SaveContext().saving(entity).setJoinTransaction(false)` for saving.

```java
import io.jmix.core.DataManager;
import io.jmix.core.event.EntityChangedEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.transaction.event.TransactionalEventListener;

@Component
public class AccountAfterCommitListener {

    private static final Logger log = LoggerFactory.getLogger(AccountAfterCommitListener.class);

    private final DataManager dataManager;

    public AccountAfterCommitListener(DataManager dataManager) {
        this.dataManager = dataManager;
    }

    @TransactionalEventListener
    public void onAccountChangedAfterCommit(EntityChangedEvent<Account> event) {
        if (event.getType() == EntityChangedEvent.Type.DELETED) {
            return;
        }
        try {
            Account account = dataManager.load(event.getEntityId())
                    .joinTransaction(false)
                    .one();
            // notify an external system about `account`
        } catch (Exception e) {
            log.error("Error handling Account changes after commit", e);
        }
    }
}
```

**The criterion is the direction of failure.**
A handler that must be able to REJECT the operation belongs before commit. A handler
that mutates a resource the database transaction cannot roll back — file storage, an
external API, an outbound notification — belongs AFTER commit, however required it is.

The mistake this prevents: deleting an uploaded file from a before-commit handler
because the deletion is "a required synchronous side effect". `EntityChangedEvent` is
published before commit, so if anything later aborts the transaction the row is
still there and its file is gone — the exact inverse of the leak the handler exists to
prevent.

`EntityChangedEvent` (before commit) is delivered AFTER the SQL flush. If the write
being validated can itself violate a database constraint, the constraint error is
raised first and the listener never runs.

### Deleted entities

Use `EntityChangedEvent.Type.DELETED` to detect deletes. Deleted entity instances cannot be loaded by `event.getEntityId()` because they have already been removed, so delete-side logic must use the old values and old reference ids available from `event.getChanges()`.

For `Type.DELETED`, `event.getChanges()` carries the pre-delete values of the entity's attributes — unlike `Type.UPDATED`, where only actually-mutated attributes appear. So `getOldValue(name)` works for scalar attributes too, and to-one references come back as ids through `getOldReferenceId(name)` (to-many: `getOldCollection(name, Class)`):

```java
@EventListener
public void onLedgerEntryChanged(EntityChangedEvent<LedgerEntry> event) {
    if (event.getType() == EntityChangedEvent.Type.DELETED) {
        Integer amount = event.getChanges().getOldValue("amount");               // scalar pre-delete value
        Id<Account> accountId = event.getChanges().getOldReferenceId("account"); // reference as id
        if ("LOCKED".equals(event.getChanges().getOldValue("type"))) {
            throw new UnsupportedOperationException("This record cannot be deleted");
        }
    }
}
```

Verified on 1.4.4: `getOldValue("amount")` returns the deleted row's amount, `getOldReferenceId("account").getValue()` the account id, and the exception keeps the row.

The change set covers the deleted entity's OWN attributes. A reference is snapshotted as
an `Id` only, so the referenced entity's columns are not reachable through it — load
the referenced entity by that id if you need them.

#### A child removed by a database cascade produces no event at all

When a parent is hard-deleted and its children go with it through an `ON DELETE CASCADE`
foreign key, no hook sees those children. There is nothing to subscribe to and no state
left to read.

So any per-row cleanup a cascaded child owns — file storage, external APIs — must run
BEFORE the parent delete is requested (load the children, clean up, then remove the parent,
in a service method), or be accepted and recorded as a gap. Do not plan it as delete-side
listener work; there is no event to hang it on.

## EntitySavingEvent and EntityLoadingEvent

`EntitySavingEvent` contains the entity instance before it is written to the data store (`getEntity()`, `isNewEntity()`). Use it for required defaults, value normalization, and transformations that must be persisted with the current save operation.

It is published for created and updated instances only: `remove` publishes no `EntitySavingEvent` (in 1.4.4 `JpaDataStore.saveAll` publishes it, `deleteAll` does not). To react to removals as well (cache invalidation, audit), listen to `EntityChangedEvent` and check `Type.DELETED`.

`EntityLoadingEvent` contains the loaded entity instance after it is read from the data store. Use it to initialize non-persistent attributes from local persistent fields, for example decrypting a stored value into a transient UI-facing property.

For `EntitySavingEvent` and `EntityLoadingEvent`, read and write only local attributes of the event entity. Do not assume referenced entities are loaded or that loading references inside an `EntityLoadingEvent` will cascade loading events predictably.

### EntityLoadingEvent runs for every fetch plan

The listener fires for every load of the entity, including loads with a narrow plan
such as `_instance_name` (lookup fields, `entityPicker` captions). Reading an attribute
outside that plan throws `IllegalStateException: Cannot get unfetched attribute [type]
from detached object` — and the exception fails the whole `load`, not just the
listener (verified on 1.4.4). Guard each read:

```java
@EventListener
public void onLedgerEntryLoading(EntityLoadingEvent<LedgerEntry> event) {
    LedgerEntry entry = event.getEntity();
    if (entityStates.isLoaded(entry, "number") && entityStates.isLoaded(entry, "type")) {
        entry.setDisplayLabel(entry.getNumber() + " / " + entry.getType());
    }
}
```

(`entityStates` is an injected `io.jmix.core.EntityStates`.)

### Reading a reference you nevertheless need

Inside `EntitySavingEvent` an unloaded reference does NOT lazy-load — the getter
throws `IllegalStateException: Cannot get unfetched attribute [account] from detached
object` (1.4.4 disables lazy loading for the save transaction). That is an exception to
the ordinary rule (outside the save path a reference missing from the fetch plan is
lazy-loaded and only local attributes throw), so code written from the general rule
fails here. A typical trigger: the entity was loaded with `_local` / `_base` and only a
scalar was changed before `save()`.

This also rules out the obvious workaround: `dataManager.load(Account.class)
.id(entry.getAccount().getId())` never runs, because `entry.getAccount()` throws
first. `entity.getRef().getId()` is not a safe way to learn a reference's id — it
needs the reference loaded.

```java
@EventListener
public void onLedgerEntrySaving(EntitySavingEvent<LedgerEntry> event) {
    LedgerEntry entry = event.getEntity();
    Account account = entityStates.isLoaded(entry, "account")
            ? entry.getAccount()
            : dataManager.load(LedgerEntry.class).id(entry.getId())
                    .fetchPlan(fp -> fp.addFetchPlan(FetchPlan.BASE)
                            .add("account", FetchPlan.BASE))
                    .optional().map(LedgerEntry::getAccount).orElse(null);
    // ... use account, keep working with `entry`
}
```

Read the reference OUT of the separately loaded instance and keep using the event's
entity. Do NOT continue with the reloaded copy and do not merge it back: it carries
what is in the database and overwrites values set in memory but not yet saved.

## Forbidden

- Wrong event import packages such as `io.jmix.core.entity.EntityChangedEvent`; use `io.jmix.core.event.EntityChangedEvent`.
- Jmix 2/3 or Flow UI types in a 1.x project (`io.jmix.flowui.*`, `jakarta.*`).
- Assuming `EntityChangedEvent` directly contains the full entity instance.
- Assuming `EntityLoadingEvent` is a replacement for fetching references or running cross-entity queries.
- Reading an attribute in an `EntityLoadingEvent` listener without an `isLoaded` guard.
- Reading an entity property that is omitted from a custom fetch plan.
- `@TransactionalEventListener` for validation, or for immutable-record enforcement — anything that must be able to reject the operation.
- Data access in an after-commit listener without `joinTransaction(false)` / `setJoinTransaction(false)`, or without try/catch and logging.
- A before-commit handler for a side effect the transaction cannot undo (file storage, external APIs, notifications).
- Putting UI code (`Notifications`, `Dialogs`, screens) in entity listeners.
- Side effects without an explicit service method when several entities must stay consistent.
