---
name: jmix-create-resource-role
description: Create or update Jmix resource and row-level roles and role assignments — entity, attribute, view, menu, and specific policies, UI login permission, "own records / only in status X" edit rules, and the CREATE-implies-MODIFY rule.
---

# Create Resource Role

Use this skill when adding or changing Jmix security access.

Resource roles are additive, with no deny policy: if any assigned resource role
grants access, the user has it. A role interface may `extend` several role
interfaces of the same kind to combine their policies; one role cannot mix
`@ResourceRole` and `@RowLevelRole`.

## Steps

1. List every entity the role must access.
2. For each entity, re-read the requirement and choose the `@EntityPolicy`
   actions from its exact wording (**Requirement wording → policy actions**).
   - If the wording forbids updating or deleting the entity ("immutable",
     "cannot be updated", "cannot be deleted", "create only"), read **When the
     requirement forbids updating or deleting an entity** below.
   - If the requirement limits which rows a user sees or edits ("own records",
     "only in status X", "own department"), read **When the requirement limits
     which rows a user can see or change** below.
3. Add `@EntityAttributePolicy` for the fields the role must view or edit. Apply
   **CREATE implies MODIFY**.
4. List in `@ViewPolicy` every view the role can open: list views, detail views,
   and detail views opened only as dialogs. If an entity is a `composition`
   property of another entity, read **When an entity is a `composition` child
   of another entity** below.
5. Add `@MenuPolicy` for the views opened from the menu, using real item ids
   from `menu.xml`, not group ids (**Menu policies**).
6. Give every UI user `ui.loginToUi` (**Every UI user needs `ui.loginToUi`**).
7. Do not grant broader actions than the workflow requires.
8. If any service, listener, scheduled job, or custom controller runs under the
   role's session and writes entities (including side effects on another entity
   when a record is saved), read **When code outside the UI saves entities for
   the role's users** below.
9. Run **Self-check before finishing**.

## Role example: read and create only

Take the actions from **Requirement wording → policy actions**, not from this
example.

```java
import io.jmix.security.model.EntityAttributePolicyAction;
import io.jmix.security.model.EntityPolicyAction;
import io.jmix.security.role.annotation.EntityAttributePolicy;
import io.jmix.security.role.annotation.EntityPolicy;
import io.jmix.security.role.annotation.ResourceRole;
import io.jmix.securityflowui.role.annotation.MenuPolicy;
import io.jmix.securityflowui.role.annotation.ViewPolicy;

@ResourceRole(name = "Employee", code = EmployeeRole.CODE)
public interface EmployeeRole {
    String CODE = "employee";

    @EntityAttributePolicy(entityClass = OrderRequest.class,
            attributes = "*",
            action = EntityAttributePolicyAction.MODIFY)
    @EntityPolicy(entityClass = OrderRequest.class,
            actions = {EntityPolicyAction.READ, EntityPolicyAction.CREATE})
    void orderRequestEntity();

    @ViewPolicy(viewIds = {
            "OrderRequest.list",
            "OrderRequest.detail"
    })
    @MenuPolicy(menuIds = "OrderRequest.list")
    void orderRequestScreens();
}
```

## Requirement wording → policy actions

| Requirement wording (about an entity)           | EntityPolicyAction         |
|-------------------------------------------------|----------------------------|
| "view only", "read only"                        | `READ`                     |
| "view and create", "create only"                | `READ`, `CREATE`           |
| "view, edit"                                    | `READ`, `UPDATE`           |
| "view, create, delete" (no update)              | `READ`, `CREATE`, `DELETE` |
| "full CRUD", "manage", "all operations"         | `ALL`                      |
| "cannot be updated", "immutable"                | do not include `UPDATE`    |
| "cannot be deleted"                             | do not include `DELETE`    |
| "cannot be updated or deleted"                  | `READ`, `CREATE` only — even for managers |

`list_read` is an open mode (read-only access), not a `readOnly` descriptor.

## CREATE implies MODIFY

If a role grants `EntityPolicyAction.CREATE` on an entity, its
`@EntityAttributePolicy` for the editable fields must be
`EntityAttributePolicyAction.MODIFY`, never `VIEW`.

- This holds even when the entity cannot be updated or deleted after creation
  (`READ` + `CREATE` only).
- Reason: an attribute with only a `VIEW` policy is modify-denied
  (`EntityAttributeContext.canModify()` returns false). A `CREATE + VIEW` user can
  persist a row but gets a create form whose fields are all read-only.
- Apply it to every role. A frequent mistake: the manager role has `MODIFY`, but a
  read/employee role that also has `CREATE` stays on `VIEW`. Both need `MODIFY`.
- If some attributes must be read-only even at creation (for example generated
  audit fields), leave them out of the `attributes` list or give that subset a
  second `VIEW` policy — not a blanket `VIEW` on `*`.

```java
// CORRECT for a read-and-create-only entity:
@EntityAttributePolicy(entityClass = <Entity>.class,
        attributes = "*", action = EntityAttributePolicyAction.MODIFY)   // MODIFY, not VIEW
@EntityPolicy(entityClass = <Entity>.class,
        actions = { EntityPolicyAction.READ, EntityPolicyAction.CREATE })
void entityPolicy();
```

## Every UI user needs `ui.loginToUi`

The login view refuses a user without the specific policy `ui.loginToUi`, whatever
else their roles grant. Give every UI user the project's `UiMinimalRole`
(`ui-minimal`: `ui.loginToUi`, `MainView`, `LoginView`): the business role extends
it, or the user gets a `ui-minimal` assignment, in seed changelogs too.

## Menu policies

Menu groups are navigation containers. Read `menu.xml` and grant the item ids that
open views; granting the enclosing `<menu id="...">` group id does not grant its
items.

```xml
<menu id="sales" title="msg://menu.sales">
    <item view="Customer.list"/>
    <item id="orders" view="Order.list"/>
</menu>
```

```java
@MenuPolicy(menuIds = {"Customer.list", "orders"})
```

Grant only `sales` only when the role intentionally controls the group itself and
the project's security checks use that group id.

## Self-check before finishing

A clean compile is not "done": most role defects pass `compileJava` and show up
only at render or in tests. Confirm each item with a concrete check, not by
re-reading your own code:

1. **CREATE ⇒ MODIFY.** In every role file, each entity granted
   `EntityPolicyAction.CREATE` has `MODIFY`, not `VIEW`, on its editable attributes.
2. **`@MenuPolicy` uses leaf ids** — the exact `<item>` ids/views in `menu.xml`.
3. **Every reachable view has a `@ViewPolicy` entry**, including composition
   dialog detail views opened from a parent grid without a menu item.
4. **Every UI user holds `ui.loginToUi`** (`ui-minimal`), seed assignments
   included.
5. **No user holds two row-level roles narrowing the same entity** unless the
   intersection is intended, including assignments of existing roles in seed
   data.

To assert a permission in Java at runtime, inject `AccessManager`, call
`applyRegisteredConstraints(...)` on a context (for example
`EntityOperationContext`), then check `isPermitted()`.

## Forbidden

- `EntityPolicyAction.ALL` when update/delete are not required.
- Any action broader than the workflow needs.
- `UPDATE` for an entity described as "immutable" or "cannot be updated";
  `UPDATE` or `DELETE` for one described as "cannot be updated or deleted" or
  "create only", even in the manager role.
- A role that grants entity actions with no `@EntityAttributePolicy`.
- `CREATE` with a `VIEW` attribute policy (or no `MODIFY`) on editable fields, in
  any role.
- A blanket `VIEW` on `*` to keep a few attributes read-only at creation.
- A UI user without `ui.loginToUi` (`ui-minimal`), seed assignments included.
- View policies only for list views while create/edit dialogs use detail views.
- Menu policy for a parent group when the user needs access to concrete menu items.
- Menu policy for views that are not menu entries.
- `@ResourceRole` and `@RowLevelRole` in one role.
- Counting a clean compile as a finished role.
- Two row-level roles narrowing the same entity on one user, unless the
  intersection is intended (seed assignments included): row-level policies are
  joined with AND.

## Special cases

### When the requirement forbids updating or deleting an entity

- "Immutable" or "cannot be updated": leave out `UPDATE`.
- "Cannot be deleted": leave out `DELETE`.
- "Cannot be updated or deleted" or "create only": `READ`, `CREATE` only, not even
  `UPDATE` or `DELETE` for the manager role.
- `EntityPolicyAction.ALL` includes `UPDATE` and `DELETE` and contradicts all of
  these.
- The attribute policy is still `MODIFY` (**CREATE implies MODIFY**): create forms
  need it even when update/delete are forbidden.

### When an entity is a `composition` child of another entity

The child's detail view opens as a dialog from the parent's detail view. That
dialog is a real Jmix view subject to `@ViewPolicy`, though no menu leads to it.
Include the child detail view id in `@ViewPolicy` of every role that can edit the
parent, and keep it out of `@MenuPolicy`.

```java
@ViewPolicy(viewIds = {
    "<Parent>.list",
    "<Parent>.detail",
    "<Child>.detail",          // composition child, opened from <Parent>.detail
})
@MenuPolicy(menuIds = {"<Parent>.list"})   // child detail is NOT in menu
void parentScreens();
```

Without the child detail id the role compiles and fails at runtime when the user
clicks "+" in the parent's composition table.

### When the requirement limits which rows a user can see or change

Wording such as "own records", "only in status X", "own department". A resource
role grants what the user can do; a row-level role restricts which rows. Put row
rules in a separate interface annotated with `@RowLevelRole`.

- `@JpqlRowLevelPolicy(entityClass = ..., where = "...")` filters in the database.
  Use `{E}` as the entity alias and `:current_user_*` parameters (for example
  `:current_user_username`).
- `@PredicateRowLevelPolicy(entityClass = ..., actions = {...})` filters in
  memory; the method returns a `RowLevelPredicate` / `RowLevelBiPredicate`. Use it
  for logic JPQL cannot express and for non-read operations.

```java
@RowLevelRole(name = "Own Orders Only", code = "app_OwnOrdersOnly")
public interface OwnOrdersOnlyRole {
    @JpqlRowLevelPolicy(entityClass = Order.class,
            where = "{E}.createdBy = :current_user_username")
    void orderPolicy();
}
```

**Row-level policies are joined with AND** — JPQL conditions and predicates alike,
across all the user's row-level roles. A user with both "own orders" and
"department orders" sees only their own. Assign only the wider role, or write one
role whose condition contains the `or`; check seed role assignments too.

A JPQL policy affects only the root entity of a loaded graph. If the entity is
also loaded as a collection inside another entity's graph, define both a
`@JpqlRowLevelPolicy` and a `@PredicateRowLevelPolicy` for it.

An UPDATE predicate is checked against two states of the entity.
`StandardDetailView` and the list `EditAction` check the entity as loaded, to
decide whether the view (or the child dialog) opens read-only. The data store
checks the entity as it is being saved, with the user's changes applied. So a
predicate on a field the same user changes in that save judges the new value: an
`Order` predicate `status == DRAFT` lets the owner edit a draft, then denies, with
`AccessDeniedException`, the owner's own save that moves the order to SUBMITTED.

- Put ownership in the predicate (the requester is the current user); it does not
  change during the save.
- Keep status rules for the entity itself in the service or the view.
- A status rule fits child entities that the transition does not touch, for
  example `OrderLine` changes allowed only while the parent `Order` is a draft.
  Then save the user's pending line edits before the status change, in a separate
  save: in one save the changed lines are checked against the parent's new status
  and denied.

### When code outside the UI saves entities for the role's users

Any service, listener, scheduled job, or custom controller running under the
role's session, including side effects on another entity when a record is saved.

- Make sure the operation has the permissions it needs on every entity it writes,
  or run it through an appropriate trusted service path.
- Attribute policies are enforced by Flow UI value bindings, grid columns, and
  `EntitySerialization`, not by `DataManager`. The data layer checks only
  entity-level and row-level rules, so such code persists an attribute the role
  was never granted, with no error. Guard the non-granted attributes in that code
  yourself.
