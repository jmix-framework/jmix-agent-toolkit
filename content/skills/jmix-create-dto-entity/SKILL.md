---
name: jmix-create-dto-entity
description: Create or change Jmix 1.x DTO entities and other non-persistent transfer models for Classic UI data containers, REST/API payloads, custom data stores, external data, or calculated read models.
---

# Create DTO Entity

Stack: Jmix 1.x (verified on 1.4.4), Classic UI (`io.jmix.ui` screens).

Use this skill when a non-JPA model must participate in Jmix metadata, UI data containers, or DataManager-backed custom data stores.

## Steps

1. Decide whether the model needs Jmix metadata.
2. Use a plain Java class (or a record, when the project compiles for Java 16+) for internal service/API payloads that are not shown in Jmix UI.
3. Use a Jmix DTO entity when the model is bound to Classic UI components (tables, forms, data containers), localized as an entity, or handled by a custom data store.
4. Create the DTO class in a package consistent with the project, usually `entity` or a dedicated DTO package if the project already has one.
5. Add `@JmixEntity`; use `annotatedPropertiesOnly = true` when only selected fields should become entity attributes.
6. Add `@JmixId` on a stable unique attribute. Add `@JmixGeneratedValue` for generated UUID ids.
7. Add `@InstanceName` when the DTO appears in pickers, tables, or captions.
8. Add `@JmixProperty(mandatory = true)` for required DTO attributes that have no JPA `@Column`.
9. Instantiate UI-bound DTO entities with `Metadata.create()` or `DataManager.create()`, not constructors.
10. Add message keys for DTO entity and attributes when user-facing.
11. Do not create Liquibase changes for pure DTO entities.

## DTO Entity Template

```java
import io.jmix.core.entity.annotation.JmixGeneratedValue;
import io.jmix.core.entity.annotation.JmixId;
import io.jmix.core.metamodel.annotation.InstanceName;
import io.jmix.core.metamodel.annotation.JmixEntity;
import io.jmix.core.metamodel.annotation.JmixProperty;

import java.math.BigDecimal;
import java.util.UUID;

@JmixEntity(annotatedPropertiesOnly = true)
public class CustomerSummary {
    @JmixId
    @JmixGeneratedValue
    @JmixProperty(mandatory = true)
    private UUID id;

    @InstanceName
    @JmixProperty(mandatory = true)
    private String name;

    @JmixProperty
    private BigDecimal totalAmount;

    private String internalNote;   // no @JmixProperty: not an entity attribute

    // getters and setters
}
```

Verified on 1.4.4: `metadata.create(CustomerSummary.class)` fills the id, while
`new CustomerSummary()` leaves it null; the metaclass has no `internalNote` property
(`findProperty` returns null) and `name` is mandatory. Without `annotatedPropertiesOnly`
every field becomes an attribute.

## Plain DTO Pattern

Use a POJO (or a record on Java 16+) when Jmix metadata is not needed:

```java
public class CustomerSummaryResponse {
    private final UUID customerId;
    private final String name;
    private final BigDecimal totalAmount;
    // constructor and getters
}
```

Do not add `@JmixEntity` just because a class is called DTO.

## UI Usage (Classic UI screen)

For a DTO collection shown in a screen, use a collection container with a loader that
has no query, and supply the data from a load delegate. This is the shape Studio 1.4
generates for a DTO browse screen:

```xml
<data readOnly="true">
    <collection id="customerSummariesDc"
                class="com.company.app.entity.CustomerSummary">
        <loader id="customerSummariesDl"/>
    </collection>
</data>
<facets>
    <dataLoadCoordinator auto="true"/>
</facets>
```

```java
import io.jmix.core.LoadContext;
import io.jmix.ui.screen.*;

@UiController("CustomerSummary.browse")
@UiDescriptor("customer-summary-browse.xml")
@LookupComponent("customerSummariesTable")
public class CustomerSummaryBrowse extends StandardLookup<CustomerSummary> {
    @Autowired
    private SummaryService summaryService;

    @Install(to = "customerSummariesDl", target = Target.DATA_LOADER)
    private List<CustomerSummary> customerSummariesDlLoadDelegate(LoadContext<CustomerSummary> loadContext) {
        return summaryService.loadSummaries();
    }
}
```

`readOnly` is an attribute of `<data>` in the 1.4 screen schema, not of `<loader>`
(`data.xsd` has no `readOnly` on loaders). A DTO container carries no `fetchPlan`: there is
nothing to fetch. Verified on 1.4.4 by opening such a screen in a `@UiTest`: the container
holds the delegate's items.

## Custom Data Store

Use `@Store(name = "...")` (`io.jmix.core.metamodel.annotation.Store`) only when a real
custom data store exists and the DTO should support generic CRUD through `DataManager`.
Without it, a DTO entity belongs to the built-in `noop` store (verified on 1.4.4), so
`dataManager.load(CustomerSummary.class).all().list()` returns an empty list and
`dataManager.save(dto)` silently persists nothing.

If the task only needs a calculated table or API response, prefer a service-returned DTO list instead of inventing a store.

## Verify — binding errors surface at screen open, not compile

A DTO whose UI-bound attribute is not a real `@JmixProperty`, or a data
container whose `class` points at the wrong type, compiles clean and then
fails when the screen is created and shown — not at application start.

1. **Annotations and packages — verify before you type them.** `@JmixId`,
   `@JmixGeneratedValue` come from `io.jmix.core.entity.annotation`;
   `@JmixEntity`, `@InstanceName`, `@JmixProperty` from
   `io.jmix.core.metamodel.annotation`. Confirm the package and members of any
   annotation new to the project in the 1.4 sources or docs
   (https://docs.jmix.io/1.x/jmix/1.4/data-model/entities.html#dto) — see
   `jmix-verify-api-symbol`.
2. **Static inspection (Gate 1).** Run `jmix-ide-static-analysis`
   (get_file_problems) on the screen XML that binds the DTO container — it flags
   a container `class` or property path that does not resolve, which the
   compiler never checks.
3. **Open the screen in a test (Gate 2).** A `@UiTest` that creates and shows the screen
   is the cheapest runtime proof; see `jmix-create-test`.
4. **Instantiate through metadata.** Use `Metadata.create()` /
   `DataManager.create()` for UI-bound DTO entities with generated ids — a
   constructor leaves the id null and the instance outside Jmix metadata.

## Forbidden

- `@Entity`, `@Table`, `@Column`, or Liquibase for pure DTO entities.
- Constructor calls for UI-bound DTO entities with generated ids.
- Missing `@JmixId` when identity matters in UI, data containers, or stores.
- Lombok `@Data` or generated `equals()` / `hashCode()` on Jmix entities.
- Making every API record a Jmix DTO entity by default.
- A `<query>` or `fetchPlan` on a DTO container's loader — supply data through the load delegate.
- Using a DTO entity to bypass proper fetch plans or security policies.
