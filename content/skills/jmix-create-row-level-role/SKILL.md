---
name: jmix-create-row-level-role
description: Create Jmix row-level roles (@RowLevelRole) that restrict WHICH rows a user can access — read AND create/update/delete per instance — via JPQL and predicate policies. See jmix-role-based-access for the model.
---

# Create Row-Level Role

Use this skill to restrict access at the ROW (entity-instance) level — not only
which rows a user can READ/see, but also which rows they can CREATE, UPDATE, or
DELETE (e.g. "see all orders but edit only your own"). Resource roles
(`jmix-create-resource-role`) grant type-level CRUD; a row-level role narrows it to
specific instances. For the overall model, scope, and the UI-login invariant, see
`jmix-role-based-access`.

A row-level role lives in its OWN interface annotated with `@RowLevelRole` and
never mixes with `@ResourceRole` — a role cannot be both kinds.

## Policy types

- `@JpqlRowLevelPolicy(entityClass = ..., where = "...")` filters at the DATABASE
  level and affects LOADING only (read): it adds a where/join clause so restricted
  rows are never returned. Use `{E}` as the entity alias and `:current_user_*`
  params (e.g. `:current_user_username`). Best for read filtering the DB can express.
- `@PredicateRowLevelPolicy(entityClass = ..., actions = {...})` is tested per
  instance and covers ANY of `READ`, `CREATE`, `UPDATE`, `DELETE` — this is how you
  gate WRITE operations per row (e.g. read all rows but UPDATE/DELETE only owned
  ones). The method returns a `RowLevelPredicate` / `RowLevelBiPredicate`; use it
  for logic JPQL cannot express and for any non-read action.

## Gotcha — JPQL policy only covers the root entity of a loaded graph

A `@JpqlRowLevelPolicy` filters the entity only when it is the ROOT of a load. If
the same entity is ALSO loaded as a *collection* inside another entity's graph, the
JPQL policy does not apply there. Define BOTH a `@JpqlRowLevelPolicy` and a
`@PredicateRowLevelPolicy` for that entity to keep access consistent across both
load paths.

## Template

```java
import io.jmix.security.role.annotation.RowLevelRole;
import io.jmix.security.role.annotation.JpqlRowLevelPolicy;

@RowLevelRole(name = "Own Orders Only", code = "app_OwnOrdersOnly")
public interface OwnOrdersOnlyRole {
    @JpqlRowLevelPolicy(entityClass = Order.class,
            where = "{E}.createdBy = :current_user_username")
    void orderPolicy();
}
```

Note: a JPQL policy method is `void` (the annotation carries the `where`). A
PREDICATE policy method is a `default` method that RETURNS the predicate.

## Predicate policy example — gating writes per row

A predicate policy gates a specific ACTION per instance. To let a user read all
orders but modify only their own, apply it to `UPDATE`/`DELETE`. Use
`RowLevelBiPredicate<T, ApplicationContext>` when you need the current user:

```java
@PredicateRowLevelPolicy(entityClass = Order.class,
        actions = {RowLevelPolicyAction.UPDATE, RowLevelPolicyAction.DELETE})
default RowLevelBiPredicate<Order, ApplicationContext> onlyOwnOrdersEditable() {
    return (order, applicationContext) -> {
        CurrentAuthentication auth = applicationContext.getBean(CurrentAuthentication.class);
        return order.getCreatedBy() != null
                && order.getCreatedBy().equals(auth.getUser().getUsername());
    };
}
```

When the current user is not needed, return a plain `RowLevelPredicate<T>`:

```java
@PredicateRowLevelPolicy(entityClass = Order.class, actions = {RowLevelPolicyAction.READ})
default RowLevelPredicate<Order> notArchived() {
    return order -> !Boolean.TRUE.equals(order.getArchived());
}
```

`RowLevelPolicyAction` (`io.jmix.security.model.RowLevelPolicyAction`) has values
`READ`, `CREATE`, `UPDATE`, `DELETE`. Verify the `RowLevelPredicate` /
`RowLevelBiPredicate` import via `jmix-verify-api-symbol`.

## Steps

1. Create the `@RowLevelRole` interface (separate from any `@ResourceRole`).
2. Add a `@JpqlRowLevelPolicy` for DB-level read filtering, using `{E}` and
   `:current_user_*` params.
3. Add a `@PredicateRowLevelPolicy` where JPQL cannot express the rule, or where the
   entity is also loaded as a nested collection (see the gotcha above).
4. Assign the row-level role to users alongside their resource role(s).

## Forbidden

- Mixing `@RowLevelRole` and `@ResourceRole` policies in one interface.
- A JPQL policy alone for an entity also loaded as a nested collection (add the
  predicate policy too).
- Using a row-level role to GRANT a base operation — the resource role must first
  grant the action on the entity type; a row-level predicate only NARROWS an
  already-granted operation to specific instances (it cannot enable an operation
  the resource role denies).
