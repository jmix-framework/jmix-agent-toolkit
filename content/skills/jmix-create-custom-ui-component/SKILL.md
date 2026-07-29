---
name: jmix-create-custom-ui-component
description: Integrate a custom Vaadin Flow UI component into a Jmix app — frontend web component, server component, XML loader, and Spring registration.
---

# Create Custom UI Component

Use this skill to add a UI component Jmix does not ship — a web component written
from scratch or a wrapper around an existing JS/npm library — and make it usable
in view XML descriptors.

A working integration is FOUR artifacts (+ two optional). Create them together: a
missing loader or registration means the XML tag never resolves at runtime. Verify
every Jmix/Vaadin symbol before typing it (`jmix-verify-api-symbol`).

## Steps

1. **Frontend web component** — a `LitElement` under `src/main/frontend/`.
2. **Server component** — a class extending `com.vaadin.flow.component.Component`,
   annotated with `@Tag` (client tag) and `@JsModule` (path to the frontend file).
3. **Loader** — extends `io.jmix.flowui.xml.layout.loader.AbstractComponentLoader<T>`;
   creates the component and reads its XML attributes.
4. **Registration** — a Spring `@Configuration` `@Bean` returning
   `io.jmix.flowui.sys.registration.ComponentRegistration`, binding tag → component → loader.
5. *(optional)* **XSD schema** — tag/attribute autocompletion in view descriptors.
6. *(optional)* **Studio metadata** — `@StudioUiKit`/`@StudioComponent` interface so the
   component shows in Studio's visual View Designer palette.

## 1. Frontend (LitElement)

`src/main/frontend/component/my-slider/my-slider.js` — the tag MUST contain a hyphen:

```javascript
import {html, LitElement} from 'lit';
import {defineCustomElement} from '@vaadin/component-base/src/define.js';

export class MySlider extends LitElement {
    static get is() { return 'my-slider'; }
    static get properties() {
        return { value: {type: Number, notify: true} };
    }
    render() {
        return html`<input type="range" .value="${this.value}"
            @input="${e => { this.value = e.target.valueAsNumber; }}"/>`;
    }
}
defineCustomElement(MySlider);
```

Files under `src/main/frontend/` are SOURCE you edit. Never edit `frontend/generated/**`
(regenerated every build). The `@JsModule` path is relative to the frontend root:
`./component/my-slider/my-slider.js`.

## 2. Server component

```java
import com.vaadin.flow.component.*;
import com.vaadin.flow.component.dependency.JsModule;
import com.vaadin.flow.shared.Registration;

@Tag("my-slider")
@JsModule("./component/my-slider/my-slider.js")
public class MySlider extends Component implements HasSize {

    private static final String VALUE = "value";
    private static final String VALUE_CHANGED = "value-changed";

    @Synchronize(property = VALUE, value = VALUE_CHANGED)
    public int getValue() {
        return getElement().getProperty(VALUE, 0);
    }

    public void setValue(int value) {
        getElement().setProperty(VALUE, value);
    }

    public Registration addValueChangeListener(ComponentEventListener<ValueChangedEvent> listener) {
        return addListener(ValueChangedEvent.class, listener);
    }

    @DomEvent(VALUE_CHANGED)
    public static class ValueChangedEvent extends ComponentEvent<MySlider> {
        private final int value;
        public ValueChangedEvent(MySlider source, boolean fromClient,
                                 @EventData("event.detail.value") int value) {
            super(source, fromClient);
            this.value = value;
        }
        public int getValue() { return value; }
    }
}
```

Standard contracts are Vaadin mixin interfaces — implement only what applies:
`HasSize`, `HasEnabled`, `HasStyle`, `HasLabel`, `HasTooltip`.

## 3. Loader

`factory`, `element`, `resultComponent` are protected members of `AbstractComponentLoader`.

```java
import io.jmix.flowui.xml.layout.loader.AbstractComponentLoader;

public class MySliderLoader extends AbstractComponentLoader<MySlider> {
    @Override
    protected MySlider createComponent() {
        return factory.create(MySlider.class);
    }
    @Override
    public void loadComponent() {
        loadInteger(element, "value", resultComponent::setValue);
        componentLoader().loadSizeAttributes(resultComponent, element);
    }
}
```

## 4. Registration

```java
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
the client `@Tag` (`my-slider`).

## Data binding (value components)

For a component that holds a value, extend
`com.vaadin.flow.component.AbstractSinglePropertyField<C, T>` — it implements Vaadin's
`HasValue` end to end (syncs one client property; gives `getValue`/`setValue`/
`addValueChangeListener`), so drop the manual property/event code above:

```java
public class MySlider extends AbstractSinglePropertyField<MySlider, Integer> {
    public MySlider() { super("value", 0, false); } // (clientProperty, defaultValue, acceptNullValues)
}
```

To bind it to an entity attribute in a view (`<mySlider dataContainer="dc" property="..."/>`),
the component must additionally support a Jmix value source and the loader must load it.
Verify the exact value-source interface and loader call against an existing Jmix field
component or Context7 before typing them — do not guess these symbols.

## Use in a view descriptor

The XSD `targetNamespace` (optional step 5) must equal the `xmlns` used here:

```xml
<view xmlns="http://jmix.io/schema/flowui/view"
      xmlns:app="http://myapp/schema/component">
    <layout>
        <app:mySlider value="50"/>
    </layout>
</view>
```

## Forbidden

- A `@Tag` without a hyphen — custom elements REQUIRE a dash.
- Component without its loader, or loader without the `@Bean` registration — the tag will not resolve.
- Reusing the client `@Tag` value as the XML element name — they are independent.
- Editing generated frontend files (`frontend/generated/**`).
