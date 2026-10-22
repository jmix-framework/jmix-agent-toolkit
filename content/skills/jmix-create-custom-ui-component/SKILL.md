---
name: jmix-create-custom-ui-component
description: Create or integrate custom Jmix Flow UI components, web components, or JS-library wrappers, including XML loaders, registration, standard contracts, entity data binding, and Studio metadata.
---

# Create Custom UI Component

Use this skill to make a custom component usable in view XML descriptors in a
Jmix 3 / Vaadin 25 application. First check whether a shipped Jmix/Vaadin component
already meets the need. For a composition of existing server components, prefer
`Composite` or `CustomField`; a new frontend module is only needed for a new web
component or JS-library wrapper.

For a new web component, create the frontend, Java component, loader, and
registration together. Verify every Jmix/Vaadin symbol before typing it
(`jmix-verify-api-symbol`). Adapt packages to the application; the Java examples
below use `com.company.app.component`.

## Steps

1. **Frontend web component** — a `LitElement` under `src/main/frontend/`.
2. **Server component** — `Component` for non-value components, or a Vaadin field
   base class for value components, with `@Tag` and `@JsModule`.
3. **Loader** — extends `io.jmix.flowui.xml.layout.loader.AbstractComponentLoader<T>`;
   creates the component and reads its XML attributes.
4. **Registration** — a Spring `@Configuration` `@Bean` returning
   `io.jmix.flowui.sys.registration.ComponentRegistration`, binding tag → component → loader.
5. *(optional)* **XSD schema** — XML tag/attribute validation and completion.
6. *(optional)* **Studio metadata** — `@StudioUiKit`/`@StudioComponent` interface so the
   component shows in Studio's visual View Designer palette.

## 1. Frontend (LitElement)

`src/main/frontend/component/my-slider/my-slider.js` — an illustrative integer
slider (0–100). For a standard slider, use Jmix's shipped slider instead. A new
custom element's tag must contain a hyphen:

```javascript
import {css, html, LitElement} from 'lit';
import {defineCustomElement} from '@vaadin/component-base/src/define.js';

export class MySlider extends LitElement {
    static styles = css`
        :host { display: inline-block; }
        input { box-sizing: border-box; width: 100%; margin: 0; }
    `;
    static get is() { return 'my-slider'; }
    static get properties() {
        return {
            value: {type: Number},
            disabled: {type: Boolean},
            readonly: {type: Boolean},
            label: {type: String}
        };
    }
    constructor() {
        super();
        this.value = 0;
        this.disabled = false;
        this.readonly = false;
        this.label = '';
    }
    render() {
        return html`<label><span>${this.label}</span>
            <input type="range" min="0" max="100" .value=${this.value ?? 0}
                ?disabled=${this.disabled || this.readonly}
                @input=${this.onInput}>
        </label>`;
    }
    onInput(event) {
        this.value = event.target.valueAsNumber;
        this.dispatchEvent(new CustomEvent('value-changed', {
            detail: {value: this.value}, bubbles: true, composed: true
        }));
    }
}
defineCustomElement(MySlider);
```

Files under `src/main/frontend/` are SOURCE you edit. Never edit `frontend/generated/**`
(regenerated every build). The `@JsModule` path is relative to the frontend root:
`./component/my-slider/my-slider.js`.

Lit does not implement Polymer's `notify: true`: dispatch `value-changed`
explicitly after changing the host's numeric `value`. Emit it for user input,
not for server property writes. Keep frontend and Java defaults equal. A range
cannot display an empty value; this example displays null at 0 without writing
back until the user edits. Use an input with an empty state if that distinction
must be visible, and enforce the 0–100 domain in the model as well.

For an npm wrapper, declare the dependency with Vaadin's `@NpmPackage`, import
the library in the frontend module, and forward its value/events to this same
host-property contract. Dispose library listeners/resources when detached.

## 2. Server component

```java
package com.company.app.component;

import com.vaadin.flow.component.AbstractSinglePropertyField;
import com.vaadin.flow.component.HasLabel;
import com.vaadin.flow.component.HasSize;
import com.vaadin.flow.component.Tag;
import com.vaadin.flow.component.dependency.JsModule;
import io.jmix.flowui.component.delegate.FieldDelegate;
import io.jmix.flowui.data.SupportsValueSource;
import io.jmix.flowui.data.ValueSource;
import org.springframework.context.ApplicationContext;
import org.springframework.context.ApplicationContextAware;

@Tag("my-slider")
@JsModule("./component/my-slider/my-slider.js")
public class MySlider extends AbstractSinglePropertyField<MySlider, Integer>
        implements HasSize, HasLabel, SupportsValueSource<Integer>, ApplicationContextAware {
    private FieldDelegate<MySlider, Integer, Integer> fieldDelegate;

    public MySlider() {
        super("value", 0, true);
    }

    @Override
    @SuppressWarnings("unchecked")
    public void setApplicationContext(ApplicationContext applicationContext) {
        fieldDelegate = applicationContext.getBean(FieldDelegate.class, this);
    }

    @Override
    public ValueSource<Integer> getValueSource() {
        return fieldDelegate.getValueSource();
    }

    @Override
    public void setValueSource(ValueSource<Integer> valueSource) {
        fieldDelegate.setValueSource(valueSource);
    }
}
```

`AbstractSinglePropertyField` supplies `getValue` / `setValue` /
`addValueChangeListener` and synchronizes `value` on `value-changed`; do not add a
second manual `@Synchronize` / `@DomEvent` value implementation. The last
constructor argument permits null from nullable entity attributes.

`SupportsValueSource` plus `FieldDelegate` implements Jmix entity binding; Vaadin's
`HasValue` alone is insufficient. Create the component through `UiComponents`
(as the loader does), so Spring supplies its delegate before binding. For a
programmatic binding, use
`slider.setValueSource(new ContainerValueSource<>(taskDc, "progress"))`
(`io.jmix.flowui.data.value.ContainerValueSource`).

Implement standard contracts only when their behavior works in the browser.
Here `HasSize` supplies size/style, `HasLabel` sets the host's `label`, and the
field base supplies enabled/read-only support. Vaadin writes **`readonly`**
(lowercase); the frontend must apply it and `disabled` to the inner input. A
range has no native read-only mode, so both disable interaction in this example.
The wrapping `<label>` gives the input an accessible name. Add `HasTooltip`,
validation/error presentation, or focus contracts only with their corresponding
frontend behavior; follow an existing Jmix field for `SupportsValidation` and
`HasValidation` when validation is needed.

## 3. Loader

`factory`, `element`, `resultComponent` are protected members of `AbstractComponentLoader`.

```java
package com.company.app.component;

import io.jmix.flowui.xml.layout.loader.AbstractComponentLoader;
import io.jmix.flowui.xml.layout.support.DataLoaderSupport;

public class MySliderLoader extends AbstractComponentLoader<MySlider> {
    @Override
    protected MySlider createComponent() {
        return factory.create(MySlider.class);
    }
    @Override
    public void loadComponent() {
        applicationContext.getBean(DataLoaderSupport.class, context)
                .loadData(resultComponent, element);
        loadInteger(element, "value", resultComponent::setValue);
        componentLoader().loadLabel(resultComponent, element);
        componentLoader().loadEnabled(resultComponent, element);
        componentLoader().loadValueAndElementAttributes(resultComponent, element);
        componentLoader().loadSizeAttributes(resultComponent, element);
    }
}
```

`AbstractComponentLoader` loads the component id and visibility. Load every
additional XML attribute you expose; an XSD or Studio property alone has no
runtime effect. Do not combine a literal `value` with entity binding.

## 4. Registration

```java
package com.company.app.component;

import io.jmix.flowui.sys.registration.ComponentRegistration;
import io.jmix.flowui.sys.registration.ComponentRegistrationBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class MySliderRegistration {
    @Bean
    public ComponentRegistration mySlider() {
        return ComponentRegistrationBuilder.create(MySlider.class)
                .withComponentLoader("mySlider", MySliderLoader.class)
                .build();
    }
}
```

The `withComponentLoader` tag (`mySlider`) is the XML element name — independent of
the client `@Tag` (`my-slider`); they may also be the same. Keep the configuration
within Spring's component scan. A reusable add-on must expose it through its
module configuration. Choose a unique local XML tag name: a namespace prefix
does not isolate it from another registered loader with the same local name.

## Use in a view descriptor

The XSD `targetNamespace` (optional step 5) must equal the `xmlns` used here:

```xml
<view xmlns="http://jmix.io/schema/flowui/view"
      xmlns:app="http://myapp/schema/component">
    <layout>
        <app:mySlider id="progressField" value="50"
                      label="msg://progress" width="100%"/>
    </layout>
</view>
```

Add `progress` to the view's message bundle (`jmix-add-i18n-keys`). For entity
binding, declare an instance container `taskDc` with an Integer attribute
`progress`, then replace the literal `value` with
`dataContainer="taskDc" property="progress"`. Test both a saved value and null.

## 5. XSD (optional)

Create `src/main/resources/app-ui-components.xsd`, with `targetNamespace` equal
to the view's `xmlns:app`:

```xml
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
           targetNamespace="http://myapp/schema/component"
           elementFormDefault="qualified">
    <xs:element name="mySlider">
        <xs:complexType>
            <xs:attribute name="id" type="xs:string"/>
            <xs:attribute name="visible" type="xs:boolean"/>
            <xs:attribute name="value" type="xs:integer"/>
            <xs:attribute name="label" type="xs:string"/>
            <xs:attribute name="enabled" type="xs:boolean"/>
            <xs:attribute name="readOnly" type="xs:boolean"/>
            <xs:attribute name="width" type="xs:string"/>
            <xs:attribute name="height" type="xs:string"/>
            <xs:attribute name="minWidth" type="xs:string"/>
            <xs:attribute name="maxWidth" type="xs:string"/>
            <xs:attribute name="minHeight" type="xs:string"/>
            <xs:attribute name="maxHeight" type="xs:string"/>
            <xs:attribute name="dataContainer" type="xs:string"/>
            <xs:attribute name="property" type="xs:string"/>
        </xs:complexType>
    </xs:element>
</xs:schema>
```

Keep this sample schema standalone so XML tools can validate it without importing
framework layout definitions. Expose additional attributes only with matching
loader behavior. Map the application namespace to `app-ui-components.xsd` in the
IDE if it is not discovered. Validate both literal and data-bound elements;
invalid integer/Boolean values must fail. XSD completion does not register the
runtime loader.

## 6. Studio metadata (optional)

Place the interface in application sources and use the component's actual FQN.
Keep `xmlElement`, `xmlns` and `xmlnsAlias` consistent with the view and XSD:

```java
package com.company.app.component;

import io.jmix.flowui.kit.meta.StudioComponent;
import io.jmix.flowui.kit.meta.StudioProperty;
import io.jmix.flowui.kit.meta.StudioPropertyType;
import io.jmix.flowui.kit.meta.StudioUiKit;

@StudioUiKit
public interface AppUiKit {
    @StudioComponent(name = "MySlider", classFqn = "com.company.app.component.MySlider",
            category = "Components", xmlElement = "mySlider",
            xmlns = "http://myapp/schema/component", xmlnsAlias = "app",
            properties = {
                    @StudioProperty(xmlAttribute = "value", type = StudioPropertyType.INTEGER),
                    @StudioProperty(xmlAttribute = "dataContainer", type = StudioPropertyType.DATA_CONTAINER_REF),
                    @StudioProperty(xmlAttribute = "property", type = StudioPropertyType.PROPERTY_REF)
            })
    void mySlider();
}
```

List any other supported attributes as Studio properties when exposing them in
the property editor. Metadata controls the palette and descriptor editing;
custom frontend rendering in Designer preview may require a supported preview
loader in the project's Studio version. Verify palette and preview separately.

## Verify

- Compile Java and build the Vaadin frontend; confirm the module and npm imports resolve.
- Instantiate through `UiComponents` and load an XML descriptor using `app:mySlider`.
- In a browser, change the value with pointer and keyboard: Java gets a numeric
  value and one client value-change event; server `setValue` updates the input
  without a spurious client event. Check defaults, null, label, disabled and read-only.
- Bind to an Integer entity attribute: load, edit, save and reopen; confirm both
  container-to-component and component-to-container updates. Check the null policy.
- If schema/metadata were added, validate the XML and check Studio palette,
  properties and preview. Run `jmix-ide-static-analysis` and `jmix-verify-bootrun`.

## Forbidden

- A new custom element's `@Tag` without a hyphen (native tags such as `input` are valid).
- Component without its loader, or loader without the `@Bean` registration — the tag will not resolve.
- Treating Lit's `notify: true` as an event implementation.
- Claiming entity binding from `HasValue` alone, or advertising mixins without frontend support.
- Editing generated frontend files (`frontend/generated/**`).
