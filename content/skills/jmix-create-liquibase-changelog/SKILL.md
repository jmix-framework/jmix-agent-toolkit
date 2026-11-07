---
name: jmix-create-liquibase-changelog
description: Create Liquibase changelogs that exactly match Jmix 1.x entity model changes, placed where the Jmix 1.4 project layout picks them up automatically.
---

# Create Liquibase Changelog

Stack: Jmix 1.x (verified on 1.4.4) — Liquibase 4.11.0 (managed by the Jmix BOM),
HSQLDB 2.5 by default.

Use this skill for every persistent entity or schema change.

## How Jmix 1.4 finds changelogs

There is no `spring.liquibase.change-log` in a Jmix 1.4 project. At startup Jmix
(`io.jmix.data.impl.liquibase.LiquibaseChangeLogProcessor`) builds a master changelog that
`<include>`s `/<base-package>/liquibase/changelog.xml` of **every Jmix module** on the
classpath — the framework modules, every add-on, and the application itself (its base
package, e.g. `/com/company/app/liquibase/changelog.xml`). An additional data store
uses `/<base-package>/liquibase/<store>-changelog.xml` the same way.

The application's own `changelog.xml`, as rendered by the 1.4 project template:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<databaseChangeLog
        xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
                      http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-3.8.xsd">

    <!-- DO NOT REMOVE. This is a master changelog that runs all other changelogs. -->

    <property name="uuid.type" dbms="oracle" value="varchar2(32)"/>
    <property name="uuid.type" dbms="!oracle" value="uuid"/>

    <includeAll path="/com/company/app/liquibase/changelog"/>

</databaseChangeLog>
```

So the application changelogs live in `src/main/resources/<base-package>/liquibase/changelog/`
and run in file-name order (`010-init-user.xml` is the template's first one). Keep the
`dbchangelog-3.8.xsd` header the project's files already use; Liquibase 4.11 also accepts a
`dbchangelog-4.11.xsd` header (both verified), but do not mix styles without a reason.

## Steps

1. Open `<base-package>/liquibase/changelog.xml` and see how it reaches the change files
   (`<includeAll>` in the template, explicit `<include>` in some projects).
2. Follow the existing naming style: numbered files (`020-...xml`) or date folders, so
   the new file sorts AFTER every file it depends on.
3. Create a new changelog file for the schema change.
4. Make sure it is reachable from that `changelog.xml`: usually by placing it under the directory covered by `<includeAll>`, or by adding an explicit `<include>` only when the project uses explicit includes.
5. Check whether the project also keeps a **baseline** changelog — one that creates the whole schema for a fresh database. If it does, mirror the change there too. See "Baseline changelogs" below.
6. Use a changeset id and author that match project style; do not reuse an id within the same changelog file.
7. Add `ID` and `VERSION` columns for standard Jmix entities.
8. Add every persistent entity field with exact type, length, precision, scale, and nullability.
9. Add foreign keys for references.
10. Add indexes and unique constraints required by the entity or domain.
11. Verify the table and column names match Java annotations.
12. Use only type macros already present in the project (the template defines only `${uuid.type}`). If no macro exists, use the standard Liquibase type.
13. Run `clean test`: the Spring context start applies the changelogs, so a broken changeset fails the context-load test.

**The 1.4 template's tests share the development database.** There is no test
datasource: `application.properties` points `main.datasource.url` at the file database
`jdbc:hsqldb:file:.jmix/hsqldb/<project>`, and the test context uses it too. A test run
therefore APPLIES your changesets to the dev database for good; editing one of them
afterwards is "modifying an applied changeset" (checksum failure at the next start).
While a changelog is still unreleased and you need to change it, delete
`.jmix/hsqldb/` (the database is recreated from the changelogs) rather than piling up
fix-up changesets — never do this to a shared or production database.

The template's own changesets carry `context="!cuba"` (a CUBA-migration switch). Copy it
into new changesets only if the project's other changesets use it.

## Standard Types

| Java type | Liquibase type |
| --- | --- |
| UUID | `${uuid.type}` |
| String | `varchar(n)` |
| Integer | `int` |
| Long | `bigint` |
| BigDecimal | `decimal(p,s)` |
| Boolean | `boolean` |
| LocalDate | `date` |
| LocalDateTime | `timestamp` |
| `java.util.Date` with `@Temporal(TIMESTAMP)` (audit, soft delete) | `timestamp` |
| OffsetDateTime / ZonedDateTime | `timestamp with time zone` |
| `@Lob` String (unlimited text) | `clob` |
| `@Lob` byte[] | `blob` |
| FileRef | `varchar(1024)` |
| Enum id string | `varchar(50)` |

A column NAME is not a free choice either: if it is a reserved word in any
targeted dialect the `createTable` fails there, and the dialects disagree —
PostgreSQL rejects `END` outright (check with
`select catcode from pg_get_keywords() where word = '<lower-case name>'`) while
HSQLDB 2.5 (the 1.4 default) rejects `ORDER` but accepts `START`, `END`, `LANGUAGE`,
`USER` and `NUMBER` without a warning.
Liquibase emits the name unquoted, so this surfaces only when the changelog
first reaches the production dialect. Rename instead of quoting (the template's convention is a trailing underscore: `USER_`). See
`jmix-create-entity` (Column names).

An entity with an **assigned natural key** takes the id column type of its Java
field — `bigint` for a `Long` id, not `${uuid.type}`. See `jmix-create-entity`
(Id strategy).

An entity extending a `@MappedSuperclass` inherits its key, and often a version,
audit or tenant columns with it. No field in the subclass names them, but the table
must still create them: read the superclass and take each inherited column's name and
type from there — do not assume `${uuid.type}` for the primary key.

## Entity Table Skeleton

```xml
<changeSet id="1" author="app">
    <createTable tableName="CUSTOMER">
        <column name="ID" type="${uuid.type}">
            <constraints nullable="false" primaryKey="true" primaryKeyName="PK_CUSTOMER"/>
        </column>
        <column name="VERSION" type="int">
            <constraints nullable="false"/>
        </column>
        <column name="NAME" type="varchar(100)">
            <constraints nullable="false"/>
        </column>
    </createTable>
</changeSet>
```

## Changing an existing table — `addColumn`, never a second `createTable`

Widening an entity that already exists (see `jmix-create-entity`, "Widening an
existing entity") means a NEW changelog file with `addColumn`. Do not edit the
original `createTable` changeset — it is already applied, and changing it breaks
the checksum and hard-fails startup.

```xml
<changeSet id="1" author="app">
    <addColumn tableName="CUSTOMER">
        <column name="NOTES" type="clob"/>
        <column name="LAST_CONTACTED_AT" type="timestamp with time zone"/>
        <column name="MANAGER_ID" type="${uuid.type}"/>
    </addColumn>
</changeSet>

<!-- FK and index for the new reference column: a separate changeset -->
<changeSet id="2" author="app">
    <addForeignKeyConstraint baseTableName="CUSTOMER" baseColumnNames="MANAGER_ID"
                             referencedTableName="EMPLOYEE" referencedColumnNames="ID"
                             constraintName="FK_CUSTOMER_ON_MANAGER"/>
    <createIndex indexName="IDX_CUSTOMER_MANAGER" tableName="CUSTOMER">
        <column name="MANAGER_ID"/>
    </createIndex>
</changeSet>
```

Rules for a widening changelog:

- A column added to a table that already has rows CANNOT be `nullable="false"`
  without a default or a data fix — existing rows have no value. Add it nullable,
  or add it with a `defaultValue`, or backfill with `<update>` and then tighten.
- The column type comes from the Java field, see Standard Types above.
- Read the table's ORIGINAL changelog first and match its naming and type style.

## Index parity — the changelog is only half of it

Every index in a changelog must also exist as an `@Index` in the entity's
`@Table(indexes = {...})`, with the SAME name — and the reverse. Nothing enforces
this: `compileJava`, the Jmix inspection, and a green `clean test` all pass when
the index exists only in the changelog. Write both sides in the same edit, while
you still remember the column. See `jmix-create-entity` (Index parity).

## One-time data fixes — `<update>`, and how to write NULL

A schema change sometimes needs a matching data fix (backfilling a new column,
clearing a timestamp so a job reprocesses every row). That is an ordinary
`<update>` changeset.

```xml
<!-- literal value -->
<changeSet id="3" author="app">
    <update tableName="CUSTOMER">
        <column name="STATUS" value="PENDING"/>
    </update>
</changeSet>

<!-- set to NULL: a <column> with NO value attribute at all -->
<changeSet id="4" author="app">
    <update tableName="CUSTOMER">
        <column name="LAST_CONTACTED_AT"/>
        <column name="LAST_INVOICED_AT"/>
    </update>
</changeSet>
```

`value=""` is NOT null — on most databases it writes an empty string, and on a
non-text column it fails. To write NULL, omit every `value`/`valueXxx` attribute.
Add a `<where>` clause when the fix targets a subset of rows; without one it
updates every row, which is usually what a one-time reset wants.

## Audit and soft-delete columns

If the entity carries audit (`@CreatedBy` / `@CreatedDate` / `@LastModifiedBy` /
`@LastModifiedDate`) or soft-delete (`@DeletedBy` / `@DeletedDate`) annotations,
add the matching columns INSIDE its `<createTable>`. They are set by Jmix at
runtime, so keep them NULLABLE (no `nullable="false"`). Add only the columns
whose annotations are actually on the entity — see `jmix-create-entity`
(Auditing and Soft Delete).

```xml
<column name="CREATED_BY" type="varchar(255)"/>
<column name="CREATED_DATE" type="timestamp"/>
<column name="LAST_MODIFIED_BY" type="varchar(255)"/>
<column name="LAST_MODIFIED_DATE" type="timestamp"/>
<column name="DELETED_BY" type="varchar(255)"/>
<column name="DELETED_DATE" type="timestamp"/>
```

## Parent → child ordering (FK references must follow the parent table)

When a child table has a foreign key to a parent, the parent `createTable`
MUST come BEFORE the child's `createTable` / `addForeignKeyConstraint`. A
changeSet that references a table not yet created fails at startup and takes
down the whole context — including tests that only touch the data model.
Order the parent first, the child (with its FK) second:

```xml
<!-- parent FIRST -->
<changeSet id="create-parent" author="app">
    <createTable tableName="PARENT">
        <column name="ID" type="${uuid.type}">
            <constraints nullable="false" primaryKey="true" primaryKeyName="PK_PARENT"/>
        </column>
        <column name="VERSION" type="int"><constraints nullable="false"/></column>
        <column name="NAME" type="varchar(100)"><constraints nullable="false"/></column>
    </createTable>
</changeSet>

<!-- child SECOND: its FK references the already-created parent -->
<changeSet id="create-child" author="app">
    <createTable tableName="CHILD">
        <column name="ID" type="${uuid.type}">
            <constraints nullable="false" primaryKey="true" primaryKeyName="PK_CHILD"/>
        </column>
        <column name="VERSION" type="int"><constraints nullable="false"/></column>
        <column name="NAME" type="varchar(100)"><constraints nullable="false"/></column>
        <column name="PARENT_ID" type="${uuid.type}"><constraints nullable="false"/></column>
    </createTable>
    <addForeignKeyConstraint baseTableName="CHILD" baseColumnNames="PARENT_ID"
                             referencedTableName="PARENT" referencedColumnNames="ID"
                             constraintName="FK_CHILD_ON_PARENT"/>
</changeSet>
```

For a **composition** child, which layer actually removes the child rows depends
on the **parent's** deletion traits. Check them before choosing `onDelete`:

- **Parent carries `@DeletedDate`/`@DeletedBy`** (soft delete): the cascade is
  enforced by Jmix at the application layer (`@Composition` +
  `@OnDelete(DeletePolicy.CASCADE)` on the entity), NOT by the database. The
  parent row is never physically deleted, so a DB-level `onDelete="CASCADE"`
  would not fire. Leave the FK without `onDelete`.
- **Parent carries neither** (hard delete): the application-layer policy never
  runs, so the annotation is inert and the database clause is the ONLY thing that removes the children. 
  The child's FK MUST carry `onDelete="CASCADE"`.

## Two referential actions on one row

`onDelete` is not an independent per-constraint choice once two foreign keys can
act on the **same row in one statement**. The common shape is a self-referencing
table that also belongs to a cascading owner:

```
EMPLOYEE(DEPARTMENT_ID -> DEPARTMENT ON DELETE CASCADE,
         MANAGER_ID    -> EMPLOYEE   ON DELETE SET NULL)
```

Deleting a department whose head reports to a manager in that same department
makes `FK_EMPLOYEE_ON_DEPARTMENT` delete the row while `FK_EMPLOYEE_ON_MANAGER`
sets its `MANAGER_ID` to null. 

In this case, separate statements from the application side: clear or delete the self-references first, 
then delete the owner.

## Application changelog reachability

```xml
<includeAll path="/com/company/app/liquibase/changelog"/>
```

If the project uses explicit includes instead of `includeAll`, follow that existing style:

```xml
<include file="/com/company/app/liquibase/changelog/030-customer.xml"/>
```

## Baseline changelogs — the dated file is not always the whole job

Some projects keep a BASELINE alongside the dated migrations: one changelog that
creates every table for a fresh database, and usually a second one that adds every
FK and index. A fresh database builds the schema from the baseline and MARK_RANs the
dated migrations through their own preconditions, instead of replaying years of
history.

Read the root `changelog.xml` and look at what else it includes. Two signs of a
baseline: it creates tables that predate the current release, and its changesets carry
`<validCheckSum>ANY</validCheckSum>`. That marker is there so the baseline can be
APPENDED TO in place — it is the one exception to "never edit an applied changeset".

When a project has one, a schema change lands in both places, in the same commit:

- the dated migration — for databases that already exist;
- the baseline — put the `createTable` (or a new `<column>` on the table's existing
  `createTable`) INSIDE the existing changeset, next to related tables; add the FK and
  each index as a NEW changeset in the constraints changelog, following that file's own
  pattern.

Keep every name identical across the dated file, the baseline and the entity's
`@Table(indexes = ...)`.

## Jmix add-on changelogs — included automatically in 1.4

Adding an add-on starter dependency is enough for its tables: the add-on is a Jmix
module, and its `/<addon-base-package>/liquibase/changelog.xml` is included by the
generated master changelog (see "How Jmix 1.4 finds changelogs"). Do NOT add an
`<include file="/io/jmix/<addon>/liquibase/changelog.xml"/>` to the application's
`changelog.xml` — the add-on changesets would be reached twice. Proof in the template
itself: `010-init-user.xml` inserts into `SEC_ROLE_ASSIGNMENT`, a table created by the
security-data module's changelog that the application never includes.

Order follows module dependencies, so an application changeset may reference add-on
tables. After adding an add-on, still exercise a feature that uses its tables: a green
context-load test proves the changelogs ran, not that the feature works.

## Forbidden

- New changelog file that is not reachable from `<base-package>/liquibase/changelog.xml`.
- Reusing a changeset id in the same changelog file.
- Modifying a changeset already applied to a DB: it changes the checksum and Liquibase hard-fails at startup. Add a NEW changeset instead.
- Raw `UUID` type instead of `${uuid.type}`.
- Invented type macros such as `${datetime.type}` when the project does not define them.
- Missing `VERSION`.
- Nullable database column for a required Java field.
- Java precision/length different from Liquibase precision/length.
- Missing FK for persistent references.
- A child table / FK changeSet ordered BEFORE the parent table it references.
- A second `createTable` for a table that already exists, when the change is new columns (use `addColumn`).
- `nullable="false"` on a column added to a populated table without a default or a backfill.
- `value=""` where NULL is meant — omit the value attribute instead.
- An index in the changelog with no matching `@Index` in the entity's `@Table`.
- An explicit `<include>` of a Jmix module or add-on changelog in the application changelog — 1.4 includes them itself.
- `spring.liquibase.change-log` or a hand-made master changelog replacing the Jmix-generated one.
- A dated migration with no matching entry in the project's baseline changelogs, when
  the project keeps one.
