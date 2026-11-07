---
name: jmix-configure-fetch-plan
description: Configure or audit Jmix 1.x fetch plans in Classic UI screen descriptors, fragments, DataManager loads, repositories, and entity events when loading references, avoiding N+1 queries, fixing unfetched attribute errors, or tuning data loading.
---

# Configure Fetch Plan

Stack: Jmix 1.x (verified on 1.4.4), EclipseLink, Classic UI screens (`io.jmix.ui`).

Use this skill when a task changes what entity attributes or references are loaded.

Built-in plans: `_local` (`FetchPlan.LOCAL`, local attributes only), `_base`
(`FetchPlan.BASE`, local attributes plus what the `@InstanceName` needs through
`@DependsOnProperties`), `_instance_name` (`FetchPlan.INSTANCE_NAME`, only what the instance
name needs). The constants are in `io.jmix.core.FetchPlan`.

## Steps

1. Identify every property read by the screen, service, listener, column generator, mapper, or assertion.
2. Start with `_base` unless there is a measured reason to load a partial entity.
3. Check the effective inherited plan before adding references for detached access or table display. Add only missing properties or nested attributes.
4. For browse screens, include only references and scalar columns that are displayed or used by generators/actions.
5. For editor screens and compositions, include edited reference properties and child collections that the form or table uses.
6. For service/listener code, add a fluent `DataManager.fetchPlan(...)` or named plan before reading references after load.
7. Avoid deep nested collections; prefer a second focused load when a graph becomes wide or multi-collection.
8. Check custom fetch plans against every `getX()` call after load.
9. Verify property names and run the load path before trusting the plan (see **Verify** below).

`_base` can already include references needed by an `@InstanceName` method's
`@DependsOnProperties`. Inspect those dependencies and the effective nested plan
before repeating the reference or introducing a shared plan. Inclusion alone does
not prove that every nested attribute a consumer reads is fetched: compare against
step 1 and exercise the actual detached access path.

## XML Pattern (screen descriptor `<data>`)

```xml
<data readOnly="true">
    <collection id="salesOrdersDc"
                class="com.company.app.entity.SalesOrder">
        <fetchPlan extends="_base">
            <property name="customer" fetchPlan="_instance_name"/>
            <property name="lines" fetchPlan="_base">
                <property name="product" fetchPlan="_instance_name"/>
            </property>
        </fetchPlan>
        <loader id="salesOrdersDl">
            <query>
                <![CDATA[select e from SalesOrder e]]>
            </query>
        </loader>
    </collection>
</data>
```

This is the shape Studio 1.4 generates (an inline `<fetchPlan>` inside the container). A
named plan goes on the container as an attribute instead: `<collection id="..." class="..."
fetchPlan="order-with-lines">`. `readOnly` belongs on `<data>`; the 1.4 loader element has
no such attribute. A `<property>` may carry a `fetchPlan` attribute AND nested
`<property>` children at the same time.

Use the JPA/Jmix entity name in JPQL, not the database table name.

## DataManager Pattern

```java
List<SalesOrder> orders = dataManager.load(SalesOrder.class)
        .query("select e from SalesOrder e")
        .fetchPlan(fp -> fp.addFetchPlan(FetchPlan.BASE)
                .add("customer", FetchPlan.INSTANCE_NAME))
        .list();
```

For an event listener that reads a reference:

```java
SalesOrder order = dataManager.load(SalesOrder.class)
        .id(orderId)
        .fetchPlan(fp -> fp.addFetchPlan(FetchPlan.BASE)
                .add("customer", FetchPlan.BASE))
        .one();
```

A reusable plan object comes from the `FetchPlans` bean:

```java
FetchPlan plan = fetchPlans.builder(SalesOrder.class)
        .addFetchPlan(FetchPlan.BASE)
        .add("customer", FetchPlan.INSTANCE_NAME)
        .add("lines", FetchPlan.BASE)
        .build();
```

### A reference property needs the TWO-argument `.add(...)`

```java
.add("customer", FetchPlan.BASE)   // RIGHT: nested plan for the reference
.add("customer")                   // WRONG for a reference: EMPTY nested plan
```

The one-argument `.add("customer")` compiles, runs, and loads the reference —
with an **empty** nested fetch plan. Nothing fails at load time; the failure comes
later, the first time anything reads an attribute of `customer` (reproduced on 1.4.4):

```
IllegalStateException: Cannot get unfetched attribute [name] from detached object
```

This is easy to miss because the one-argument form is perfectly correct for a
**scalar** property (`.add("orderDate")`). Only references need the second
argument: `FetchPlan.INSTANCE_NAME` when a table or caption shows the reference,
`FetchPlan.BASE` when code reads its other attributes. Under `_instance_name`, reading
any attribute outside `@InstanceName`/`@DependsOnProperties` throws the same error — in a
screen too (verified: `customer.getEmail()` on an item of the screen above).

### A dotted path `add("a.b", PLAN)` leaves `a` without its own attributes

```java
.add("order.customer", FetchPlan.BASE)          // WRONG if you also read order's own fields
.add("order", o -> o.addFetchPlan(FetchPlan.BASE)
        .add("customer", FetchPlan.BASE))       // RIGHT
```

A dotted path pulls the intermediate reference in only as a HOLDER for the nested
attribute. `order` enters the plan for the sake of `customer`, and its own
attributes are NOT loaded — so the first read of `order.getNumber()` throws the same
`Cannot get unfetched attribute` as the one-argument form above (reproduced on 1.4.4).
Read it as "order at a minimum, plus its customer", not "order in full, plus its customer".

### Single-table inheritance — a base-class load does not fetch subclass attributes

Given an abstract `Payment` with a concrete subclass `CardPayment` in one table:
`dataManager.load(Payment.class)` builds its default `_base` plan from the **requested**
metaclass's own properties only. It never includes attributes declared by subclasses,
even though the row that comes back IS the subclass. So this throws (reproduced on 1.4.4):

```java
Payment loaded = dataManager.load(Payment.class).id(id).one();
String authCode = ((CardPayment) loaded).getAuthCode();
// IllegalStateException: Cannot get unfetched attribute [authCode] ... [detached]
```

A plain cast-and-read is never enough. Two fixes:

```java
// (a) load through the CONCRETE subclass — its default plan has the subclass's
//     own attributes, so getAuthCode() is fetched
CardPayment payment = dataManager.load(CardPayment.class).id(id).one();
String authCode = payment.getAuthCode();

// (b) still polymorphic, but the follow-up read goes through a plan built
//     against the CONCRETE class — name the subclass attributes explicitly
CardPayment payment = dataManager.load(CardPayment.class)
        .id(baseTyped.getId())
        .fetchPlan(fp -> fp.addFetchPlan(FetchPlan.BASE).add("authCode"))
        .one();
```

The same applies to a **reference** typed as the base class: reading a
subclass-only attribute off it needs a re-load through the concrete subclass, as
in (b). Nothing catches this before runtime — the line that would fail is exactly
the kind of code a test must run.

## Fetch Modes

Set per-property fetch mode (`io.jmix.core.FetchMode`) to control how references are loaded:

- `AUTO` — framework picks the optimal mode (default).
- `JOIN` — loads the reference in the same SQL query; best for to-one references.
- `BATCH` — loads references in a separate `IN`-clause query; best for to-many collections (avoids N+1).
- `UNDEFINED` — separate SELECT per reference attribute.

In XML the attribute is `fetch` (NOT `fetchMode`; the 1.4 `data.xsd` defines exactly
`AUTO | UNDEFINED | JOIN | BATCH`). In Java it is the third argument of `add(...)`:

```xml
<fetchPlan extends="_base">
    <property name="customer" fetchPlan="_instance_name" fetch="JOIN"/>  <!-- to-one -->
    <property name="lines" fetchPlan="_base" fetch="BATCH"/>             <!-- to-many -->
</fetchPlan>
```

```java
.add("lines", FetchPlan.BASE, FetchMode.BATCH)
```

### `BATCH` works one level down, NOT for a NESTED collection — measure, do not assume

Measured on 1.4.4 with SQL logging (5 orders × 2 lines):

- `SalesOrder` list with `lines` BATCH → ONE `... FROM ORDER_LINE WHERE ORDER_ID IN (?,?,?,?,?)`. Works.
- `OrderLine` list with `order` → `lines` BATCH (a collection nested under a reference) →
  `... FROM ORDER_LINE WHERE ORDER_ID = ?` repeated once per parent order, although the
  DEBUG log of `io.jmix.eclipselink.impl.FetchGroupManager` still prints
  `Fetch modes for ...: e.order=JOIN, e.order.lines=BATCH`.

So `fetch="BATCH"` is not a reliable cure for N+1 on a nested collection (the builder's
plan is installed as an EclipseLink `LOAD_GROUP`, not a `FETCH_GROUP`, because
`loadPartialEntities()` is false; `partial()` is no fix). When a measurement shows the
per-parent queries, take the collection OUT of the fetch plan and load it for the whole
page with one query instead:

```java
// one query for the page, not one per parent
List<OrderLine> lines = dataManager.load(OrderLine.class)
        .query("select e from OrderLine e where e.order.id in :ids")
        .parameter("ids", orderIds)
        .list();
```

Only a count of executed SQL proves which shape you got (`logging.level.eclipselink.logging.sql = debug`
in `application.properties` — the template already has the line at `info`): `compileJava`,
the IDE inspection, and a green `clean test` all pass either way. A test that asserts the
query count does not grow with page size is the guard.

A to-one with `FetchMode.JOIN` nested inside a top-level `BATCH` collection
(`lines` BATCH → `product` JOIN) loaded fine on 1.4.4. Jmix 3 throws an EclipseLink
`NullPointerException` for that shape; if a 1.x project hits that NPE, drop the JOIN.

## JmixDataRepository

- **A derived query method (`findByNumber(...)`) loads with `_local` by default in 1.4**
  (`JmixAbstractQuery.fetchPlan = FetchPlan.LOCAL`), not `_base`. References are not in
  `_local`, so every `getCustomer()` on the result is lazy-loaded — one extra SELECT per row.
- Select the plan in one of two ways: pass an `io.jmix.core.FetchPlan` as the **last**
  method argument, or annotate the method with `@FetchPlan("name")`
  (`io.jmix.core.repository.FetchPlan`). Using both on one method throws
  `DevelopmentException`. A plain `String` parameter is bound as an ordinary query
  parameter, NOT a plan selector.
- The CRUD methods take a plan directly: `findById(id, fetchPlan)`, `getById(id, fetchPlan)`,
  `findAll(fetchPlan)`.

```java
public interface SalesOrderRepository extends JmixDataRepository<SalesOrder, UUID> {

    List<SalesOrder> findByNumber(String number);            // _local

    @FetchPlan("_base")
    List<SalesOrder> findByNumberStartingWith(String prefix);

    List<SalesOrder> findByAmountGreaterThan(BigDecimal amount, io.jmix.core.FetchPlan fetchPlan);
}
```

## What a missing attribute does depends on its KIND

Each row reproduced on 1.4.4:

| missing from the plan | behaviour |
| --- | --- |
| a local (scalar) attribute | `IllegalStateException: Cannot get unfetched attribute` — no rescue |
| a reference, ordinary code | lazy-loaded: a silent extra SELECT per row, and the reference arrives with all its local attributes |
| a reference, inside `EntitySavingEvent` | `IllegalStateException: Cannot get unfetched attribute [product]` — lazy loading is not available there |

## Partial Entity Audit

Use a partial fetch plan only when it is intentionally narrower than `_base`
(`fp -> fp.add("number")` with no `addFetchPlan(...)` loads `number` and the system
attributes only):

- The loaded entity is wide or the result list is large.
- Every local property read later is listed in the plan.
- UI components, column generators, validators, and mappers do not access omitted attributes.
- Tests cover the path that previously caused the performance issue or unfetched attribute error.

## Shared Plans

Prefer inline XML or fluent `DataManager` fetch plans for feature-local needs.

Use a shared `fetch-plans.xml` only when the same complex graph is reused in multiple
places. Register it with the `jmix.core.fetch-plans-config` property (read by
`FetchPlanRepositoryImpl` in 1.4) and keep the plan name stable.

## Verify — compile is blind to fetch plans

`compileJava` never reads screen XML or fetch-plan property names, and **the Spring
context start does not parse screen descriptors either** — a misspelled property passes
`clean test` unless a test opens that screen. A missing reference is invisible until the
load path runs: a detached entity throws `IllegalStateException: Cannot get unfetched
attribute [...]` when the table renders, or when a service/test reads `getX()` after load.
The gate is never the compiler.

1. **Property names — verify before you type them.** Every `<property name="...">` in a
   `<fetchPlan>` and every `.add("...")` in a fluent plan must be a real attribute of the
   entity, and the `FetchPlan` constants (`FetchPlan.BASE`, `FetchPlan.LOCAL`,
   `FetchPlan.INSTANCE_NAME`) and built-in plan names (`_base`, `_local`,
   `_instance_name`) must be spelled exactly. Confirm against the entity source, the 1.4
   docs (https://docs.jmix.io/1.x/jmix/1.4/data-access/fetching.html), or IDE symbol
   search — see `jmix-verify-api-symbol`.
2. **Static inspection (Gate 1).** Run `jmix-ide-static-analysis` (get_file_problems) on
   the screen/fragment XML — the Studio inspection flags an invalid property path inside
   a `<fetchPlan>` that the compiler ignores.
3. **Open the screen / run the load path (Gate 2).** A `@UiTest` that creates and shows
   the screen fails on a bad name with
   `IllegalArgumentException: Property 'customr' not found in SalesOrder` (verified on
   1.4.4); see `jmix-create-test`. For services, exercise the smallest test that reads
   the references — only this catches an attribute that is mapped but never fetched.

## Forbidden

- `FetchType.EAGER` to solve loading problems.
- The one-argument `.add("reference")` for a reference property — it builds an empty nested plan.
- Casting a base-class-typed load to a subclass and reading a subclass-only attribute.
- Reading local attributes omitted from a partial fetch plan.
- Loading references inside loops when a fetch plan can load them with the root query.
- Relying on a derived repository method's default plan for references — it is `_local`.
- Trusting `fetch="BATCH"` to remove N+1 on a nested collection without counting the executed SQL.
- Deep multi-collection graphs in a single list load.
- Using fetch plans as a security boundary.
- `@Table` names in JPQL queries.
- Shared named fetch plans for one-off local screen needs.
