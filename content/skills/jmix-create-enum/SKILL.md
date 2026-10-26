---
name: jmix-create-enum
description: Create a Jmix 1.x enum (EnumClass from io.jmix.core.metamodel.datatype.impl) for entity attributes with stable database ids and localization.
---

# Create Jmix Enum

Stack: Jmix 1.x (verified on 1.4.4), `javax.*`, Classic UI.

Use this skill when an entity attribute has a fixed set of values.

## Steps

0. **Look for an existing enum convention in the project first.** Many codebases
   have a shared base interface that every enum implements, often with a default
   `getId()` — see "Joining an existing enum family" below. Match it instead of
   introducing a second scheme.
1. Create the enum in the `entity` package.
2. Implement `io.jmix.core.metamodel.datatype.impl.EnumClass<T>` — note the `.impl`
   package in Jmix 1.x; T is `String` or `Integer`.
3. Use stable database ids, not display labels.
4. Add a typed `fromId()` method annotated with `@Nullable` from `javax.annotation`
   (the JSR-305 annotation Jmix 1.x itself uses; `org.jspecify` is not on a 1.x classpath).
5. Store the enum id type in the entity field.
6. Add getter/setter conversion in the entity.
7. Add Liquibase column matching the id type.
8. Add enum message keys in all locale files — see `jmix-add-i18n-keys` for the `<package>/<EnumClass>.<CONSTANT>` key shape (e.g. `com.company.app.entity/CustomerGrade.GOLD`), NOT an all-dots `FQCN.CONSTANT` form.

## Enum Template

```java
import io.jmix.core.metamodel.datatype.impl.EnumClass;

import javax.annotation.Nullable;

public enum CustomerGrade implements EnumClass<String> {
    BRONZE("B"),
    GOLD("G");

    private final String id;

    CustomerGrade(String id) {
        this.id = id;
    }

    @Override
    public String getId() {
        return id;
    }

    @Nullable
    public static CustomerGrade fromId(String id) {
        for (CustomerGrade at : CustomerGrade.values()) {
            if (at.getId().equals(id)) {
                return at;
            }
        }
        return null;
    }
}
```

`import io.jmix.core.metamodel.datatype.EnumClass` (no `.impl`) is the Jmix 2/3 location
and does not compile on 1.4 (`cannot find symbol`). Code ported from a newer project, or
written from newer docs, trips on this first.

A constant may carry further constructor arguments and accessors beside the stable id. They are invisible to the
metamodel, so extra state needs no message key and appears in no fetch plan. Only the **stable id** is ever persisted —
never a second field, however convenient its value looks as a column.

## Entity Mapping

```java
@Column(name = "GRADE", length = 50)
private String grade;

public CustomerGrade getGrade() {
    return grade == null ? null : CustomerGrade.fromId(grade);
}

public void setGrade(CustomerGrade grade) {
    this.grade = grade == null ? null : grade.getId();
}
```

The field holds the id; the getter/setter pair is typed by the enum, and that is what the
metamodel exposes as the attribute's type. Verified on 1.4.4: `setGrade(GOLD)` stores `G`
in the column and the reload returns `CustomerGrade.GOLD`.

Message keys, in every locale bundle (`messages_<locale>.properties`; the 1.4 template has one bundle per locale and no plain `messages.properties`, see `jmix-add-i18n-keys`):

```properties
com.company.demo14.entity/CustomerGrade=Customer grade
com.company.demo14.entity/CustomerGrade.BRONZE=Bronze
com.company.demo14.entity/CustomerGrade.GOLD=Gold
```

`messages.getMessage(CustomerGrade.GOLD)` returns `Gold` with these keys.

## Stable-id type-chain

Keep one consistent id type across `EnumClass<T>`, `getId()`/`fromId()`, the entity field, and the Liquibase column (e.g. all `String`/`varchar`, or all `Integer`/`int`). A mismatch compiles cleanly but silently corrupts load/save. Each literal id must be a hardcoded stable value, never a display label or `ordinal()`/`name()`.

When binding an enum attribute in a Classic UI screen, a `<form>` field for it renders a
`comboBox` by itself; a standalone component is `<comboBox property="grade" .../>` (its
options come from the enumeration) — not `entityComboBox`, which is for entity
references.

## Joining an existing enum family

Before writing the template above, grep for a base interface the project's enums
already implement:

```bash
grep -rn "implements .*EnumClass" src/main/java --include='*.java' | head
```

If one exists and its `getId()` returns `name()`, **match it**. The `.name()`
prohibition below is about not introducing that scheme into a project that has no
id convention yet — it is not a reason to make one new enum the only member of a
family with a different id scheme.

## Forbidden

- `io.jmix.core.metamodel.datatype.EnumClass` or `io.jmix.core.EnumClass` — in 1.x the interface is `io.jmix.core.metamodel.datatype.impl.EnumClass`.
- Raw `EnumClass` without a type parameter.
- Storing display labels as ids.
- `ordinal()` persistence, or introducing `.name()` ids into a project that has no enum id convention yet (an established project-wide convention is matched, not split — see above).
- Missing enum message keys.
