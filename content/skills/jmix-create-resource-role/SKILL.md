---
name: jmix-create-resource-role
description: Create or update Jmix 1.x resource and row-level roles and role assignments (Classic UI) — entity, attribute, screen, menu, and specific policies, the ui-minimal / ui.loginToUi login permission, "own records / only in status X" rules, and the CREATE-implies-MODIFY rule.
---

# Create Resource Role

Stack: Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui`, Vaadin 8 screens).
Screen and menu policies come from `io.jmix.securityui.role.annotation`
(`@ScreenPolicy`, `@MenuPolicy`). The Flow UI annotations
(`io.jmix.securityflowui...`, `@ViewPolicy`) belong to Jmix 2+/Flow UI and do not
apply to a Classic UI project.

Use this skill when adding or changing Jmix security access.

Resource roles are ADDITIVE / no-deny: if any assigned resource role grants access
the user has it, and there is no deny-policy. Row-level roles only narrow (see
"Row-Level roles"). A role interface may `extend` other role interfaces of the
SAME kind to compose their policies: the role builder reads every method of the
interface, inherited ones included. A role cannot mix `@ResourceRole` and
`@RowLevelRole`.

## Every UI user needs `ui.loginToUi` (role `ui-minimal`)

`LoginScreenSupport.authenticate(...)` checks the specific policy `ui.loginToUi`
(`io.jmix.securityui.accesscontext.UiLoginToUiContext`) after the password is
accepted. A user without it gets an "Access denied" notification on the login
screen and the log line `Attempt of login to UI for user '<name>' without
'ui.loginToUi' permission`, whatever else their roles grant.

In Jmix 1.4 the grant comes from the FRAMEWORK role
`io.jmix.securityui.role.UiMinimalRole` (code `ui-minimal`, scope UI only): it holds
`@SpecificPolicy(resources = "ui.loginToUi")` plus screen policies for common
framework dialogs. A generated 1.4 project has no `UiMinimalRole` class of its own.
Give every UI user one of:

- the business role `extends UiMinimalRole` (import `io.jmix.securityui.role.UiMinimalRole`), or
- a separate `ui-minimal` resource-role assignment (seed changelogs included), or
- `@SpecificPolicy(resources = "ui.loginToUi")` in the business role (then the
  framework dialogs listed in `UiMinimalRole` are not granted).

The login and main screens need no `@ScreenPolicy`: screens opened in
`OpenMode.ROOT` are always permitted (`ScreensImpl.checkPermissions`).

```java
import io.jmix.securityui.role.UiMinimalRole;

@ResourceRole(name = "Ticket clerk", code = TicketClerkRole.CODE)
public interface TicketClerkRole extends UiMinimalRole {
    String CODE = "ticket-clerk";
    // ... entity / screen / menu policies
}
```

## TOP RULE — CREATE implies MODIFY

If a role grants `EntityPolicyAction.CREATE` on an entity, that entity's
`@EntityAttributePolicy` for the editable fields MUST be
`EntityAttributePolicyAction.MODIFY` — NEVER `VIEW`. This holds even when the
entity is immutable after creation (`READ` + `CREATE` only, no `UPDATE`/`DELETE`):
`VIEW` is read-only, so a user with `CREATE + VIEW` can persist a row but cannot
fill its fields. At runtime an attribute with only a `VIEW` policy is modify-denied
(`EntityAttributeContext.canModify()` returns false), so the editor's fields bound to
it are read-only — the create form is unusable.

```java
// CORRECT for an immutable-after-create entity:
@EntityAttributePolicy(entityClass = <Entity>.class,
        attributes = "*", action = EntityAttributePolicyAction.MODIFY)   // MODIFY, not VIEW
@EntityPolicy(entityClass = <Entity>.class,
        actions = { EntityPolicyAction.READ, EntityPolicyAction.CREATE })
void entityPolicy();
```

Apply this to EVERY role consistently. A frequent mistake is getting the manager
role right (`MODIFY`) but leaving a read/employee role on `VIEW` while it still has
`CREATE` — both must be `MODIFY` if both have `CREATE`. If some attributes must be
read-only even at creation (e.g. auto-generated audit fields), exclude them from the
`attributes` list or use a second `VIEW` policy for that subset — NOT a blanket
`VIEW` on `*`. `MODIFY` includes `VIEW`.

## Where attribute policies are enforced

An attribute policy is enforced by the Classic UI: value binding of fields
(`ValueBinder`), table/data grid columns, data components and list actions, all via
`io.jmix.ui.accesscontext.UiEntityAttributeContext`. The 1.4 docs list REST endpoints
as checking it too. It is NOT enforced by `DataManager` (nor `UnconstrainedDataManager`,
`EntityManager`): the data layer checks entity-level and row-level rules only. A
service, a scheduled job or a custom controller running under the role's session
persists an attribute the role holds only `VIEW` on, with no error (verified on
1.4.4). Guard the non-granted attributes in that code yourself.

## Requirement wording → policy actions

Map the EXACT wording of the requirement to entity-policy actions. Re-read the
requirement for the entity BEFORE writing the policy block.

| Requirement wording (about an entity)           | EntityPolicyAction         |
|-------------------------------------------------|----------------------------|
| "view only", "read only"                        | `READ`                     |
| "view and create", "create only"                | `READ`, `CREATE`           |
| "view, edit"                                    | `READ`, `UPDATE`           |
| "view, create, delete" (no update)              | `READ`, `CREATE`, `DELETE` |
| "full CRUD", "manage", "all operations"         | `ALL`                      |
| "cannot be updated", "immutable"                | do NOT include `UPDATE`    |
| "cannot be deleted"                             | do NOT include `DELETE`    |
| "cannot be updated or deleted"                  | `READ`, `CREATE` only — even for managers |

For an entity described as "cannot be updated or deleted", the role must NOT
grant `UPDATE` or `DELETE` — not even for the manager role.
`EntityPolicyAction.ALL` includes both and contradicts that requirement.

## Screen ids

Classic UI policies use screen ids from `@UiController`. Studio generates
`<EntityName>.browse` and `<EntityName>.edit` (`User.browse`, `User.edit`; with a
project id prefix the entity name carries it, e.g. `sample_Customer.browse`). Read the
id from the controller, never derive it. `@ScreenPolicy` also accepts
`screenClasses = {...}`.

## Composition children

For every entity that appears as a `composition` property on another entity, the
child's editor is opened as a dialog from the parent's editor. That dialog is a real
screen subject to `@ScreenPolicy` (any non-ROOT open mode is checked), even though
users never reach it from a menu — so it has no `@MenuPolicy` entry. Always include
the child editor id in `@ScreenPolicy` for every role that can edit the parent.

```java
@ScreenPolicy(screenIds = {
    "<Parent>.browse",
    "<Parent>.edit",
    "<Child>.edit",            // composition child, opened from <Parent>.edit
})
@MenuPolicy(menuIds = {"<Parent>.browse"})   // child editor is NOT in the menu
void parentScreens();
```

A `@ScreenPolicy` that lists the parent browse+edit but omits the child editor passes
compilation and fails at runtime (`AccessDeniedException`, "Access denied"
notification) when the user clicks "Create" inside the parent's composition table.

## Row-Level roles

Row-level roles are a separate first-class concept from resource roles: a resource
role grants *what* you can do, a row-level role restricts *which rows* you see. They
live in their own interface annotated with `@RowLevelRole` and never mix with
`@ResourceRole`.

- `@JpqlRowLevelPolicy(entityClass = ..., where = "...", join = "...")` filters at
  the database level. Use `{E}` as the entity alias; `where` is appended with `and`,
  `join` must start with a comma, `join` or `left join`. `:current_user_<attribute>`
  parameters (e.g. `:current_user_username`) resolve from the current user.
- `@PredicateRowLevelPolicy(entityClass = ..., actions = {...})` filters in memory.
  It goes on a `default` method that returns `RowLevelPredicate<T>`, or
  `RowLevelBiPredicate<T, ApplicationContext>` when the check needs Spring beans.
  Actions are `RowLevelPolicyAction` (`CREATE`, `READ`, `UPDATE`, `DELETE`). Use it
  for logic JPQL cannot express and for non-read operations.

**Row-level policies are joined with AND** — JPQL conditions and predicates alike,
across all the user's row-level roles. A user with both "own orders" and "department
orders" sees only their own. Assign only the wider role, or write one role whose
condition contains the `or`; check seed role assignments too.

Gotcha: a JPQL policy only affects the root entity of a loaded graph. If the same
entity is also loaded as a *collection* inside another entity's graph, define BOTH
a `@JpqlRowLevelPolicy` and a `@PredicateRowLevelPolicy` (`READ`) for it to keep access
consistent.

```java
import io.jmix.core.security.CurrentAuthentication;
import io.jmix.security.model.RowLevelBiPredicate;
import io.jmix.security.model.RowLevelPolicyAction;
import io.jmix.security.role.annotation.JpqlRowLevelPolicy;
import io.jmix.security.role.annotation.PredicateRowLevelPolicy;
import io.jmix.security.role.annotation.RowLevelRole;
import org.springframework.context.ApplicationContext;

@RowLevelRole(name = "Own tickets only", code = OwnTicketsRole.CODE)
public interface OwnTicketsRole {
    String CODE = "own-tickets";

    @JpqlRowLevelPolicy(entityClass = Ticket.class,
            where = "{E}.owner = :current_user_username")
    void ticketRead();

    @PredicateRowLevelPolicy(entityClass = Ticket.class,
            actions = {RowLevelPolicyAction.UPDATE, RowLevelPolicyAction.DELETE})
    default RowLevelBiPredicate<Ticket, ApplicationContext> ticketChange() {
        return (ticket, ctx) -> ctx.getBean(CurrentAuthentication.class)
                .getUser().getUsername().equals(ticket.getOwner());
    }
}
```

A denied predicate on save throws `io.jmix.core.security.AccessDeniedException`.

Gotcha: an UPDATE predicate is checked against two different states of the entity.
`StandardEditor` and the list `EditAction` check it against the entity as loaded, to
decide whether the editor opens read-only. The data store checks it against the
entity as it is being saved, with the user's changes applied. So a predicate on a
field that the same user changes in that save judges the NEW value: an `Order`
predicate `status == DRAFT` lets the owner edit a draft, and then denies, with
`AccessDeniedException`, the owner's own save that moves the order to SUBMITTED.

- Put ownership in the predicate (the requester is the current user); it does not change
  during the save.
- Keep status rules for the entity itself in the service or the screen.
- A status rule fits on child entities that the transition does not touch, for example
  `OrderLine` changes allowed only while the parent `Order` is a draft. Then save the
  user's pending line edits BEFORE the status change, in a separate save: in one save the
  changed lines are checked against the parent's new status and denied.

## Role assignments

Roles are linked to users by username in `RoleAssignmentEntity`
(`io.jmix.securitydata.entity.RoleAssignmentEntity`, entity `sec_RoleAssignmentEntity`,
table `SEC_ROLE_ASSIGNMENT`). `ROLE_TYPE` is `resource` or `row_level`
(`io.jmix.security.role.assignment.RoleAssignmentRoleType.RESOURCE` / `ROW_LEVEL`).
In the UI: Users screen → **Role assignments**. In a seed changelog, follow the
generated `010-init-user.xml`:

```xml
<insert tableName="SEC_ROLE_ASSIGNMENT" dbms="postgresql, mssql, hsqldb">
    <column name="ID" value="<new uuid>"/>
    <column name="VERSION" value="1"/>
    <column name="USERNAME" value="clerk"/>
    <column name="ROLE_CODE" value="ui-minimal"/>
    <column name="ROLE_TYPE" value="resource"/>
</insert>
```

The generated changelog repeats each insert for `oracle, mysql, mariadb` with the UUID
written without dashes; keep both forms. The admin's `system-full-access`
(`FullAccessRole`) grants everything with `*`, so a check done only as `admin` hides
every missing policy.

## Mechanical self-check before finishing

A clean compile is NOT "done" — most role defects survive `compileJava` and surface
only at runtime. Confirm these with concrete checks, not by re-reading your own code:

1. **CREATE ⇒ MODIFY.** For every role file, find each entity granted
   `EntityPolicyAction.CREATE` and confirm its `@EntityAttributePolicy` action on
   the editable attributes is `MODIFY`, not `VIEW`.
2. **`@MenuPolicy` uses LEAF ids, not the group id.** Read `menu.xml`. An `<item>`
   without an `id` attribute has the id of its `screen` (`<item screen="Ticket.browse"/>`
   → `Ticket.browse`). Granting the enclosing `<menu id="...">` group id does NOT grant
   its items: each item is checked on its own, and a group whose items are all denied
   is removed from the menu. A group is shown automatically when any child is granted.
3. **Every reachable screen has a `@ScreenPolicy` entry**, composition-child editors
   and screens opened from code included. A menu policy only shows the item; opening
   the screen still needs the screen policy.
4. **Every UI user holds `ui.loginToUi`** (`ui-minimal`), seed assignments included.
5. **No user holds two row-level roles narrowing the same entity** unless the
   intersection is intended.

To assert a permission in a test or in code, inject `io.jmix.core.AccessManager`,
call `applyRegisteredConstraints(...)` on a context and read it, inside
`systemAuthenticator.withUser("<username>", ...)`:

| Check | Context | Read |
|---|---|---|
| UI login | `io.jmix.securityui.accesscontext.UiLoginToUiContext` | `isPermitted()` |
| Entity CRUD | `io.jmix.core.accesscontext.CrudEntityContext(metaClass)` | `isCreatePermitted()`, `isReadPermitted()`, `isUpdatePermitted()`, `isDeletePermitted()` |
| Attribute | `io.jmix.core.accesscontext.EntityAttributeContext(metaClass, "attr")` | `canView()`, `canModify()` |
| Screen | `io.jmix.ui.accesscontext.UiShowScreenContext("Ticket.edit")` | `isPermitted()` |
| Menu item | `io.jmix.ui.accesscontext.UiMenuContext(menuItem)` (item from `MenuConfig.getRootItems()`) | `isPermitted()` |

Create the test user and its `RoleAssignmentEntity` rows with `DataManager` first; the
user's roles are read from those rows at authentication. See `jmix-create-test`.

## Steps

1. List every entity the role must access.
2. For each entity, decide CRUD actions explicitly.
3. Add attribute policies for fields the role must view or edit.
4. List every screen the role can open, including dialog-only editors.
5. Add menu policies only for real menu item ids from `menu.xml`, not group ids.
6. Give the role `ui.loginToUi` (extend `UiMinimalRole` or assign `ui-minimal`).
7. Do not grant broader actions than the workflow requires.
8. Re-check create-only workflows: create forms need `MODIFY` attribute access even when update/delete are forbidden.
9. If saving an allowed record triggers service side effects on another entity, ensure the operation has the needed permissions or is implemented through an appropriate trusted service path.

## Read/Create Without Update/Delete

```java
import io.jmix.security.model.EntityAttributePolicyAction;
import io.jmix.security.model.EntityPolicyAction;
import io.jmix.security.role.annotation.EntityAttributePolicy;
import io.jmix.security.role.annotation.EntityPolicy;
import io.jmix.security.role.annotation.ResourceRole;
import io.jmix.securityui.role.UiMinimalRole;
import io.jmix.securityui.role.annotation.MenuPolicy;
import io.jmix.securityui.role.annotation.ScreenPolicy;

@ResourceRole(name = "Employee", code = EmployeeRole.CODE)
public interface EmployeeRole extends UiMinimalRole {
    String CODE = "employee";

    @EntityAttributePolicy(entityClass = OrderRequest.class,
            attributes = "*",
            action = EntityAttributePolicyAction.MODIFY)
    @EntityPolicy(entityClass = OrderRequest.class,
            actions = {EntityPolicyAction.READ, EntityPolicyAction.CREATE})
    void orderRequestEntity();

    @ScreenPolicy(screenIds = {
            "OrderRequest.browse",
            "OrderRequest.edit"
    })
    @MenuPolicy(menuIds = "OrderRequest.browse")
    void orderRequestScreens();
}
```

`@SpecificPolicy(resources = "...")` grants a named permission for your own checks
(e.g. `"customer.notify"`), and `entityName = "*"` / `screenIds = "*"` /
`menuIds = "*"` / `resources = "*"` grant everything, as in `FullAccessRole`.

## Role Matrix

| Surface | Required? | Policy |
| --- | --- | --- |
| UI login | every UI user | `ui-minimal` / `@SpecificPolicy(resources = "ui.loginToUi")` |
| Entity CRUD | yes | `@EntityPolicy` |
| Entity attributes | yes | `@EntityAttributePolicy` |
| Browse screen | if user opens it | `@ScreenPolicy` |
| Editor/dialog screen | if user opens it | `@ScreenPolicy` |
| Menu item | if user opens it from menu | `@MenuPolicy` |

## Menu Policy Audit

Menu groups are navigation containers. Read `menu.xml` and grant the item ids that
open screens.

```xml
<menu id="sales" caption="msg://com.company.app/menu.sales">
    <item screen="Customer.browse" caption="msg://com.company.app.screen.customer/customerBrowse.caption"/>
    <item id="orders" screen="Order.browse"/>
</menu>
```

```java
@MenuPolicy(menuIds = {"Customer.browse", "orders"})
```

Granting only `sales` shows nothing: its items stay denied and the empty group is
dropped.

## Forbidden

- `EntityPolicyAction.ALL` when update/delete are not required.
- `UPDATE` or `DELETE` entity actions for immutable or create-only records.
- Entity create permission without `MODIFY` attribute permission for editable fields.
- Screen policies only for browse screens while create/edit dialogs use editors.
- Menu policy for a parent group when the user needs access to concrete menu items.
- Menu policy for screens that are not menu entries.
- A UI user without `ui-minimal` / `ui.loginToUi`.
- Flow UI security annotations (`io.jmix.securityflowui...`, `@ViewPolicy`) in a Classic UI project.
