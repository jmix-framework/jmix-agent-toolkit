---
name: jmix-create-entity
description: Create or change a persistent Jmix 1.x JPA entity (javax.persistence, EclipseLink) and its required surrounding artifacts.
---

# Create Persistent Entity

Stack: Jmix 1.x (verified on 1.4.4) — Spring Boot 2.7, EclipseLink 2.7, `javax.*`
(NOT `jakarta.*`), Liquibase 4.11, HSQLDB 2.5 by default. UI references below are
Classic UI (Vaadin 8 screens, `io.jmix.ui`); Flow UI is only a preview in 1.4 and out
of scope.

Use this skill when adding or changing a database-backed Jmix entity.

## Steps

1. Create or update the Java entity in `src/main/java/<base-package>/entity`.
   **Changing an existing entity? Read "Widening an existing entity" below first.**
2. Add Jmix and JPA metadata: `@JmixEntity`, `@Entity`, `@Table`.
3. **Choose the id strategy explicitly** — generated surrogate or assigned natural
   key. See "Id strategy" below.
4. Add `@Version`.
5. Add `@InstanceName` on a stable human-readable field or method.
6. Define columns with exact `nullable`, `length`, `precision`, and `scale` constraints from requirements.
   **Check every column name against the reserved words of every targeted dialect** — see "Column names" below.
   **A `length` of 255 is `@Column`'s own default — omit it** and let the changelog spell
   `varchar(255)`; see "Constraint Audit" below.
7. Use `FetchType.LAZY` for relationships.
8. Create the Liquibase changelog using `jmix-create-liquibase-changelog`.
9. Add entity and attribute message keys using `jmix-add-i18n-keys`.
10. Add or update screens and security roles if the entity is user-facing.
11. Before finishing, compare every required constraint against the source requirements and the Liquibase changelog.

## Entity Template

```java
import io.jmix.core.entity.annotation.JmixGeneratedValue;
import io.jmix.core.metamodel.annotation.InstanceName;
import io.jmix.core.metamodel.annotation.JmixEntity;

import javax.persistence.Column;
import javax.persistence.Entity;
import javax.persistence.Id;
import javax.persistence.Table;
import javax.persistence.Version;
import java.util.UUID;

@JmixEntity
@Table(name = "CUSTOMER")
@Entity
public class Customer {
    @JmixGeneratedValue
    @Column(name = "ID", nullable = false)
    @Id
    private UUID id;

    @Version
    @Column(name = "VERSION", nullable = false)
    private Integer version;

    @InstanceName
    @Column(name = "NAME", nullable = false, length = 100)
    private String name;

    // getters and setters
}
```

Every JPA and Bean Validation import is `javax.*` in Jmix 1.x: `javax.persistence.*`,
`javax.validation.constraints.*` (`@NotNull`, `@Email`), `javax.annotation.PostConstruct`.
A `jakarta.persistence` import does not compile (the JPA API on the classpath is the 2.2
one under the `javax` package), and code copied from a Jmix 2/3 project needs every
`jakarta.` import rewritten.

## Column names

A column name derived from the field name may be an SQL **reserved word**, and
the dialects a project targets do not agree about which words those are. The
check is per dialect, not per SQL standard: a green suite against the test store
proves nothing about the production store.

- **PostgreSQL:** `select catcode from pg_get_keywords() where word = '<lower-case name>'`
  — `reserved` cannot be used as an identifier at all. `END` is reserved;
  `START`, `LANGUAGE`, `TEXT`, `TYPE` and `NAME` are unreserved and fine.
- **HSQLDB 2.5** (the 1.4 template's store, also used by tests): it rejects `ORDER`
  (`unexpected token: ORDER`) but accepts `START`, `END`, `LANGUAGE`, `USER` and
  `NUMBER` as column names, so it will NOT warn you about most of them.

Rename the field or give it an explicit `@Column(name = "...")`. The 1.4 project
template's own convention is a trailing underscore (the user table is `USER_`), so
`NUMBER_`, `ORDER_`, `END_` match the codebase. Common offenders an entity field naturally
produces: `end`, `order`, `user`, `group`, `desc`, `number`, `references`.

## Id strategy — an explicit choice, not a default

Two strategies. Decide which one the entity needs BEFORE writing the `@Id` field;
the wrong one is expensive to change once rows and changelogs exist.

**Generated surrogate UUID** — the default for entities this application owns.
Jmix assigns the id on `DataManager.create()` / `Metadata.create()`:

```java
@JmixGeneratedValue
@Column(name = "ID", nullable = false)
@Id
private UUID id;
```

`@JmixGeneratedValue` also accepts `Long` and `Integer` ids (sequence-generated), but
UUID is what Studio generates and what the rest of this skill pack assumes.

**Assigned natural key** — when the id comes from OUTSIDE the application and must
be preserved: a numeric id from an external system being mirrored, an
externally-issued code. NO `@JmixGeneratedValue` — it makes Jmix assign the id at
creation, which is exactly what must not happen here. The writer sets the id:

```java
@Column(name = "ID", nullable = false)
@Id
private Long id;              // assigned from the source system, never generated
```

```java
ExternalAccount account = dataManager.create(ExternalAccount.class);
account.setId(dto.getId());    // caller MUST set it — create() leaves it null
dataManager.save(account);
```

Pick the assigned key when: the source system's id is the identity users and
integrations refer to, or a sync must upsert by that id (load-by-id, insert if
absent). Pick the generated surrogate otherwise — including when the external key
merely needs to be UNIQUE, which is a unique index on an ordinary column, not an
id. Match the Liquibase column type to the Java type (`bigint` for `Long`, not
`${uuid.type}`).

**Inherited key from a framework `@MappedSuperclass`** — when the entity extends a
base class the framework or an add-on ships, the key is declared there already. Write
NO `@Id`, no `@JmixGeneratedValue` and no `@Version` on the subclass. Read that
superclass before writing the changelog: it decides the id column's name AND type, and
it often contributes further columns (a version, audit or tenant columns) that the table
must still create even though no field in the subclass mentions them.

## Required references — BOTH annotations, or the field is not really required

A required `@ManyToOne` needs the constraint in two places:

```java
@JoinColumn(name = "CUSTOMER_ID", nullable = false)   // ← metamodel: mandatory
@ManyToOne(fetch = FetchType.LAZY, optional = false)  // ← JPA: not optional
private Customer customer;
```

Omitting `nullable = false` on `@JoinColumn` leaves the Jmix metamodel treating
the attribute as OPTIONAL: the UI does not require it, no validation fires, and
the failure surfaces later as a database constraint error — or as a null nobody
expected. `optional = false` alone is not enough. This is a hard rule; it holds
for every required reference, not only composition children.

## Widening an existing entity

Adding fields to an entity that already exists is a DIFFERENT task from creating
one. Change only what the requirement asks for:

- **Do NOT touch** the `@Id` field or its strategy, `@Table(name = ...)`,
  `@Version`, or the existing columns' types and constraints. An entity with an
  assigned `Long` id stays that way — do not "normalize" it to a generated UUID.
- **Add** the new fields with their exact constraints, plus new `@Index` entries in
  `@Table(indexes = {...})` if the new columns need indexing (see below).
- **Pair it with an `addColumn` changelog**, never a second `createTable` — see
  `jmix-create-liquibase-changelog` ("Changing an existing table").
- Follow the precedent already in the project: read the entity's own changelog
  before writing the new one, and match its naming and column-type style.

## Index parity — declare every index in BOTH places

When you add an index (typically on a new reference/FK column), declare it in the
entity annotation AND in the changelog:

```java
@Table(name = "SALES_ORDER", indexes = {
        @Index(name = "IDX_SALES_ORDER_ON_CUSTOMER", columnList = "CUSTOMER_ID")
})
```

```xml
<createIndex indexName="IDX_SALES_ORDER_ON_CUSTOMER" tableName="SALES_ORDER">
    <column name="CUSTOMER_ID"/>
</createIndex>
```

Same names on both sides. **No gate catches the drift** — a missing `@Index`
changes neither the metamodel nor the schema, so `compileJava` and a green
`clean test` both pass with the index in the changelog only. It breaks Studio
round-tripping (Studio diffs the entity model against the database when it generates
changelogs) and the code-as-source-of-truth convention, and it is found by nothing but this check. Do it
as you write the column, not as a later audit.

### Make it unique when the column is a natural key

For a single-column natural key that must be unique, add `unique = true` to the
`@Index` and mirror it with `unique="true"` on the `<createIndex>`:

```java
@Table(name = "PRODUCT", indexes = @Index(
        name = "IDX_PRODUCT_ON_NAME", columnList = "NAME", unique = true))
```

```xml
<createIndex indexName="IDX_PRODUCT_ON_NAME" tableName="PRODUCT" unique="true">
    <column name="NAME"/>
</createIndex>
```

For a rule that spans several columns, use a unique **constraint** rather than a
unique index — `@Table(uniqueConstraints = @UniqueConstraint(name = "UK_ORDER_LINE",
columnNames = {"ORDER_ID", "PRODUCT_ID"}))` paired with `<addUniqueConstraint
tableName="ORDER_LINE" columnNames="ORDER_ID, PRODUCT_ID"
constraintName="UK_ORDER_LINE"/>`. Same name on both sides, as above.

A user-friendly message for the violation goes into the message bundle under
`databaseUniqueConstraintViolation.<INDEX_NAME>` — the 1.4 template ships one for
`IDX_USER__ON_USERNAME`; see `jmix-add-i18n-keys`.

One rule neither can express: a **case-insensitive** uniqueness constraint cannot be
declared with `@Index`/`@UniqueConstraint` at all — it needs a functional index on
`lower(column)` and dialect-specific SQL, so decide it at design time, not when
writing the changelog.

## Required-field defaults — at the ENTITY layer, not elsewhere

When a required field "defaults to X" or is "auto-set on create/update"
(e.g. "default now()", "auto-set", "defaults to 0"), the default MUST
apply at the entity layer so a bare `DataManager.create()` +
`DataManager.save()` succeeds with the caller never touching the field.
This is the contract: programmatic paths (services, REST, tests) bypass
the UI, so a default that lives only in a screen is no default at all.

Three patterns, in order of preference:

**Constant default — field initializer**

```java
@Column(name = "QUANTITY", nullable = false)
@NotNull
private Integer quantity = 0;
```

**Initial default at creation — `@PostConstruct`**

`@PostConstruct` fires when Jmix instantiates the entity
(`DataManager.create()`, `Metadata.create()`, `DataContext.create()`),
before the caller sets any field. Works for both JPA entities and DTOs.

```java
@Column(name = "ORDER_DATE", nullable = false)
@NotNull
private LocalDate orderDate;

@PostConstruct
public void postConstruct() {
    orderDate = LocalDate.now();
}
```

Imports (Spring Boot 2.7, so `javax.*`, never `jakarta.*`): `@PostConstruct` from
`javax.annotation`; `@NotNull` / `@Email` from `javax.validation.constraints`.

**Auto-set on every save — `EntitySavingEvent` listener** (for
`lastUpdated`-style fields that must touch on UPDATE too, or for any
cross-entity defaulting):

```java
import io.jmix.core.event.EntitySavingEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

@Component
public class CustomerSavingListener {

    @EventListener
    public void onSaving(EntitySavingEvent<Customer> event) {
        event.getEntity().setLastUpdated(LocalDateTime.now());
    }
}
```

`EntitySavingEvent` fires before EVERY save (both insert and update),
so the listener covers initial and subsequent timestamps in one place.
`Customer` must declare the `lastUpdated` field; for the full event-listener
pattern see `jmix-add-entity-event-listener`. Lazy loading is NOT available inside
this event: reading a reference that the saved instance's fetch plan did not load
throws `IllegalStateException: Cannot get unfetched attribute` — see
`jmix-configure-fetch-plan`.

### Anti-patterns that look right and break tests

| Wrong placement                                    | Why it fails                                   |
|----------------------------------------------------|------------------------------------------------|
| Default set only in the editor screen's `InitEntityEvent` | Non-UI saves bypass the screen; `DataManager.save()` fails on the database NOT NULL constraint (Bean Validation does not run on save in 1.x, see below). |
| Default set only in a service mutator that runs on UPDATE | The initial INSERT has no default; `@NotNull` fails. And a test calling `DataManager` directly never enters the service. |
| Default set in an `EntityChangedEvent` listener    | The listener fires AFTER persist — too late for `@NotNull`. It reacts to saves; it does not default them. |
| Default set only in the calling UI controller      | Programmatic paths (services, REST, tests) bypass it. |

## Bean Validation does not run on save in 1.x

In Jmix 1.4.4 `DataManager.save()` does not run Bean Validation: the EclipseLink adapter sets
`javax.persistence.validation.mode=NONE` (`JmixEclipseLinkJpaVendorAdapter`) and `SaveContext`
has no validation option. Only the UI validates fields before commit. Verified: a negative
`@PositiveOrZero` price and an invalid `@Email` are saved through `DataManager`; a missing
`@NotNull` value fails only on the database NOT NULL constraint.

So annotations protect the screens, not services, REST or tests. When a constraint must
hold on every save, enforce it in an `EntitySavingEvent` listener with the
`javax.validation.Validator` bean (`jmix-add-entity-event-listener`):

```java
@EventListener
public void onProductSaving(EntitySavingEvent<Product> event) {
    Set<ConstraintViolation<Product>> violations = validator.validate(event.getEntity());
    if (!violations.isEmpty()) {
        throw new ConstraintViolationException(violations);
    }
}
```

The Jmix validator skips attributes not loaded in the saved instance, so an update of a
partially loaded entity still passes.

## Accessors

Match what the project's entities already do. Studio 1.4 and the template's `User`
entity write accessors by hand; write them by hand unless every entity in the codebase
already uses Lombok `@Getter @Setter` and its suite is green (that combination was not
re-verified on 1.4 for this skill — if you introduce it, run `clean test`).

## Composition Checklist

For parent-child aggregates:

- Parent collection has `@Composition`.
- Parent collection has `@OnDelete(DeletePolicy.CASCADE)` when child lifecycle belongs to parent **and the parent is soft-deleted** — for a hard-deleted parent see the branch below.
- Child has a non-null back reference to parent.
- Child `@ManyToOne` uses `fetch = FetchType.LAZY` and `optional = false`.
- Child join column is `nullable = false`.
- The parent editor screen edits the child collection through a nested container
  `<collection id="linesDc" property="lines"/>` inside the parent's `<instance>`
  (no loader/query of its own), and the parent fetch plan includes the child property —
  see `jmix-create-composition-editor`.
- The child's own editor screen exists, plus its role policy, when the UI opens the child in a dialog.

```java
import io.jmix.core.DeletePolicy;
import io.jmix.core.entity.annotation.OnDelete;
import io.jmix.core.metamodel.annotation.Composition;

import javax.persistence.FetchType;
import javax.persistence.JoinColumn;
import javax.persistence.ManyToOne;
import javax.persistence.OneToMany;

@Composition
@OnDelete(DeletePolicy.CASCADE)
@OneToMany(mappedBy = "order")
private List<OrderLine> lines;  // leave uninitialized — Jmix returns a NotInstantiatedList

// in OrderLine
@JoinColumn(name = "ORDER_ID", nullable = false)
@ManyToOne(fetch = FetchType.LAZY, optional = false)
private SalesOrder order;
```

Verified on 1.4.4: removing a soft-deleted parent with this mapping soft-deletes its
children (their `DELETED_DATE` is set), and the children vanish from ordinary loads.

### Cascade for a hard-deleted parent

`@OnDelete(DeletePolicy.CASCADE)` is an application-layer policy, and Jmix applies it
only to a parent that supports soft delete (in 1.4.4 `EclipselinkPersistenceSupport`
calls the delete-policy processor only when `EntityValues.isSoftDeletionSupported`). On a
parent with no `@DeletedDate`/`@DeletedBy` the annotation does nothing and the children
are orphaned — or, with the usual FK, the delete fails.

For a hard-deleted parent, put the cascade on the child's foreign key in the changelog
instead:

```xml
<addForeignKeyConstraint baseTableName="INVOICE_LINE" baseColumnNames="INVOICE_ID"
                         constraintName="FK_INVOICE_LINE_ON_INVOICE"
                         referencedTableName="INVOICE" referencedColumnNames="ID"
                         onDelete="CASCADE"/>
```

Also add `@OnDeleteInverse(DeletePolicy.CASCADE)` to the child's back reference. It does
not change runtime behavior here, but it tells Studio to emit `onDelete` when it
generates the changelog:

```java
@OnDeleteInverse(DeletePolicy.CASCADE)
@JoinColumn(name = "INVOICE_ID", nullable = false)
@ManyToOne(fetch = FetchType.LAZY, optional = false)
private Invoice invoice;
```

`jmix-create-liquibase-changelog` presents a DB-level `onDelete="CASCADE"` as the option
you almost never want, because it assumes the Jmix default of soft delete. A hard-deleted
composition parent is the exception that wording allows for.

### Delete policies on a plain reference to a hard-deleted entity

The same rule covers `@OnDeleteInverse(DeletePolicy.DENY)` / `UNLINK` on an ordinary
`@ManyToOne`: Jmix runs the delete-policy processor only when the entity being
DELETED supports soft delete. The trait that matters is on the reference's target
(`Product` when the annotation sits on `OrderLine.product`), not on the entity that
carries the annotation. On a hard-deleted target the annotation is only a hint for
Studio's FK generation. DENY then surfaces as a foreign-key violation from the
database — verified on 1.4.4 as `javax.persistence.PersistenceException` wrapping
`SQLIntegrityConstraintViolationException`, never `DeletePolicyException`.

For a hard-deleted target put the policy on the foreign key in the changelog instead
(see `jmix-create-liquibase-changelog`, "Two referential actions on one row"):

- UNLINK → `onDelete="SET NULL"` on the FK; the column must be nullable.
- DENY → a plain FK with no `onDelete`; the database rejects the delete. Tests and
  error handling must expect the persistence exception, not `DeletePolicyException`.
- CASCADE → `onDelete="CASCADE"`, as in the composition branch above.

## Auditing and Soft Delete (Studio "traits")

Studio 1.4 adds these as entity traits; written by hand they are plain annotated
fields. Audit: `@CreatedBy`, `@CreatedDate`, `@LastModifiedBy`, `@LastModifiedDate` from
`org.springframework.data.annotation`. Soft delete: `@DeletedBy`, `@DeletedDate` from
`io.jmix.core.annotation`. Soft-deleted rows are then auto-filtered out of
`DataManager`/JPQL loads.

```java
@CreatedBy
@Column(name = "CREATED_BY")
private String createdBy;

@CreatedDate
@Temporal(TemporalType.TIMESTAMP)
@Column(name = "CREATED_DATE")
private Date createdDate;          // java.util.Date, as the framework's own entities use

@LastModifiedBy
@Column(name = "LAST_MODIFIED_BY")
private String lastModifiedBy;

@LastModifiedDate
@Temporal(TemporalType.TIMESTAMP)
@Column(name = "LAST_MODIFIED_DATE")
private Date lastModifiedDate;

@DeletedBy
@Column(name = "DELETED_BY")
private String deletedBy;

@DeletedDate
@Temporal(TemporalType.TIMESTAMP)
@Column(name = "DELETED_DATE")
private Date deletedDate;
```

Verified on 1.4.4: a `DataManager.save()` under the system authentication fills
`createdBy = "system"` and both dates. Map the columns as `varchar(255)` / `timestamp`,
nullable (see `jmix-create-liquibase-changelog`).

To see soft-deleted rows (an admin restore screen, a test assertion), load with
`.hint(PersistenceHints.SOFT_DELETION, false)` (`io.jmix.data.PersistenceHints`).

The soft-delete filter applies to **writes** as well. Inserting or updating a row whose
reference points at a soft-deleted entity fails — with a message that names the wrong
cause (reproduced on 1.4.4):

```
IllegalStateException: During synchronization a new object was found through
a relationship that was not marked cascade PERSIST
```

If a reference to a soft-deleted row is a legal state in the model (a child that may sit
beneath a deleted parent), the save must carry the hint:

```java
dataManager.save(new SaveContext()
        .setHint(PersistenceHints.SOFT_DELETION, false)
        .saving(entity));
```

## Calculated and Transient Properties

Non-persistent derived attributes use `@JmixProperty` + `@Transient` +
`@DependsOnProperties({"a", "b"})` (`@JmixProperty` and `@DependsOnProperties` from
`io.jmix.core.metamodel.annotation`, `@Transient` from `javax.persistence`). The same
applies to an `@InstanceName` method: it must carry `@DependsOnProperties` listing every
attribute it reads so they are fetched by `_instance_name`.

```java
@InstanceName
@DependsOnProperties({"number", "orderDate"})
public String getDisplayName() {
    return number + " " + orderDate;
}

@JmixProperty
@Transient
@DependsOnProperties({"amount"})
public boolean isBig() {
    return amount != null && amount.compareTo(BigDecimal.valueOf(1000)) > 0;
}
```

`@DependsOnProperties` lists only the entity's own attributes; a referenced entity is
fetched with its instance name only, so don't read its other attributes in a calculated
property.

## File attributes

Use `FileRef` (`io.jmix.core.FileRef`) for an uploaded file reference. No converter
annotation is needed — verified on 1.4.4, a `FileRef` saves and reloads as is:

```java
@Column(name = "SCAN_FILE", length = 1024)
private FileRef scanFile;
```

Map the matching Liquibase column as `varchar(1024)`.

## Embeddable, Inheritance, and Data Stores

- `@Embeddable` value objects (still annotated `@JmixEntity`) are supported, as are JPA
  inheritance strategies (`@Inheritance` with `JOINED`, `SINGLE_TABLE`, or
  `TABLE_PER_CLASS`).
- For `SINGLE_TABLE`, an **abstract** base class is normal and carries NO
  `@DiscriminatorValue` of its own — it is never instantiated, so there is no row
  to discriminate. Only the concrete subclasses need one (verified on 1.4.4 with an
  abstract `Payment` and `@DiscriminatorValue("CARD")` on `CardPayment`). Subclasses
  carry `@JmixEntity` and `@Entity`, no `@Table`; the subclass columns live in the base
  table and must be nullable there.
- **Loading through the base class does not fetch subclass attributes.** A
  `dataManager.load(BaseType.class)` builds its default fetch plan from the base
  metaclass's own properties, so casting the result to a subclass and reading a
  subclass-declared attribute throws `IllegalStateException: Cannot get unfetched
  attribute` (reproduced on 1.4.4). See `jmix-configure-fetch-plan` for the fix.
- For a non-default data store, annotate the entity with `@Store(name = "...")`
  (`io.jmix.core.metamodel.annotation.Store`; the store is defined in
  `application.properties`); add-on entities use an entity-name prefix, e.g.
  `@Entity(name = "app_Customer")`.

## Constraint Audit

`compileJava` does not build the schema — Liquibase does — so Java/DDL
drift is silent. Check Java annotations and the Liquibase changelog side
by side:

- `nullable` / `@NotNull`
- `length` — compare the **effective** length, not whether the attribute is written.
  `@Column`'s own default is 255, so a 255-character column omits `length` from the
  annotation while the changelog must still spell `varchar(255)`, because SQL has no such default.
  An attribute present on one side and absent on the other is not drift here. `precision` and `scale` default to 0,
  which is never the requirement, so those are always written on both sides.
- `precision` and `scale`
- enum id values and column type
- foreign key nullability
- indexes and unique constraints
- default values for required fields

When a field uses `@PropertyDatatype`, inspect the datatype class's `@Ddl`
(`io.jmix.core.metamodel.annotation.Ddl`) too. Compare its SQL type with the intended
column and verify the effective generated DDL; matching `@Column` and Liquibase alone can
hide a conflicting datatype declaration. Do not assume the field annotation wins. Use a
compatible datatype or separate display formatting from schema typing, and review
generated migrations for unintended precision or scale changes before applying them.

## Semantic Constraint Checks

Apply common Java validation and persistence mappings when the field semantics are clear:

- Fields named `email` should usually have `@Email` (`javax.validation.constraints.Email`) unless the requirements explicitly say otherwise.
- Unlimited or large text should use `@Lob` (`javax.persistence.Lob`) plus a `clob` column, not an invented arbitrary length.
- `BigDecimal` columns must use the exact required precision and scale in both Java and Liquibase.
- Do not invent a length for a field when the requirements say it is unlimited or when the existing project uses long text for the same concept.

## Forbidden

- Missing `@JmixEntity`.
- `jakarta.persistence` / `jakarta.validation` / `jakarta.annotation` imports — Jmix 1.x is `javax.*`.
- Constructor-based entity creation.
- `@Data`, `@EqualsAndHashCode` or `@ToString` on a Jmix entity: they generate `equals`/`hashCode`/`toString` over mutable persistent fields, replacing the identity semantics the framework relies on and touching lazy references while doing it.
- `FetchType.EAGER`.
- Missing Liquibase changelog for persistent changes.
- A required `@ManyToOne` with `optional = false` but no `@JoinColumn(nullable = false)` — the metamodel then treats it as optional and the UI does not require it.
- `@JmixGeneratedValue` on an assigned natural key — Jmix then assigns the id itself, defeating the point of preserving the source system's id.
- Changing an existing entity's id strategy, `@Table` name, or `@Version` while adding fields to it.
- An index declared in the changelog but missing from `@Table(indexes = …)`, or the reverse.
- Nullable child back references in composition aggregates.
- Relying only on UI initialization for required persistence fields.
- Instantiating or replacing a collection field that Jmix populated — it may be a `NotInstantiatedList`/`NotInstantiatedSet`. Leave collection fields uninitialized; do not assign `new ArrayList`/`new HashSet`.
- A 0-byte `.java` — it passes compile and the clean test boot, but breaks the registry. Confirm every file you wrote is non-empty.
