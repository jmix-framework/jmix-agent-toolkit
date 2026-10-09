---
name: jmix-setup-main-view
description: Bring a main view that came from Jmix 2.x up to the Jmix 3 structure — user menu in the header, populated initial layout, and the filter chain the logo needs. Run after jmix-migrate-theme-to-aura. The Aura CSS ships rules for classes a 2.x descriptor never sets, so the main view renders under-styled with no error, and the logo 403s into a broken-image box while the file is present and served.
disable-model-invocation: true
---

# Set up the main view after the Aura port

Applies after `jmix-migrate-theme-to-aura`, when the project's `main-view.xml`
still has the structure it was scaffolded with under Jmix 2.x.

## Step 0 — see what the theme port did NOT do

`jmix-migrate-theme-to-aura` swaps the stylesheets. It does not touch
`main-view.xml` beyond the one `jmix-main-view-app-layout` class, so the
descriptor stays structurally 2.x while the CSS around it is Jmix 3.

Aura's generated `view/main-view.css` defines rules for classes a 2.x descriptor
never produces:

```
.jmix-main-view-user-menu      .user-menu-button-content   .user-menu-header-content
.user-menu-avatar              .user-menu-text             .user-menu-subtext
.jmix-initial-layout           .jmix-initial-layout-content
.jmix-initial-layout-title     .jmix-initial-layout-logo
```

Every one of those is dead CSS until the descriptor sets the class. Nothing
warns you — the app boots, the theme checks in `jmix-migrate-theme-to-aura` all
pass, and the main view just looks emptier than the reference project's.

```bash
# 2.x shape: identity in the drawer footer, initial layout empty
grep -n "userIndicator\|logoutButton\|<footer\|<initialLayout\|userMenu" \
     src/main/resources/**/view/main/main-view.xml
# Which of the theme's classes the descriptor actually uses
grep -oE 'jmix-initial-layout[a-z-]*|jmix-main-view-user-menu' \
     src/main/resources/**/view/main/main-view.xml | sort -u
```

A 2.x descriptor answers: `userIndicator` + `logoutButton` inside `<footer>`,
`<initialLayout>` empty, no `userMenu`, no `jmix-initial-layout*` anywhere.

## Step 1 — take the descriptor from a real Jmix 3 project, do not hand-write it

**Ask the user for the reference project** — the same one Step 1 of
`jmix-migrate-theme-to-aura` used, or a throwaway Jmix 3 project created in
Studio. Do not search the filesystem for one. Diff its `main-view.xml` and
`MainView.java` against yours and port the differences; the class names below
are a contract with the theme CSS and a typo in one fails silently.

## Step 2 — move user identity into a header user menu

In the header, after `viewTitle`:

```xml
<userMenu id="userMenu"
          themeNames="tertiary" classNames="jmix-main-view-user-menu">
    <items>
        <separator/>
        <actionItem id="substituteUserMenuItem" themeNames="non-checkable">
            <action id="substituteUserAction" type="sec_userMenuSubstituteUser"/>
        </actionItem>
        <separator/>
        <actionItem id="logoutMenuItem" ref="logoutAction" themeNames="non-checkable"/>
    </items>
</userMenu>
```

**Then delete the drawer `<footer>`** holding `userIndicator` and the logout
button. Keeping both compiles and renders, and leaves the user with two logout
controls in two places — a review comment, not an error.

Give `logoutAction` a caption, or the menu item renders blank:

```xml
<action id="logoutAction" text="msg:///actions.logout.text" type="logout"/>
```

## Step 3 — install the renderers in the controller

`userMenu` renders nothing useful without them — you get a bare button, not an
avatar and name. Port `userMenuButtonRenderer` and `userMenuHeaderRenderer` from
the reference project's `MainView`, keeping the class names exactly
(`user-menu-button-content`, `user-menu-header-content`, `user-menu-avatar`,
`user-menu-text`, `user-menu-text-subtext`, `user-menu-subtext`) — they are what
the theme CSS keys off.

```java
@Install(to = "userMenu", subject = "buttonRenderer")
private Component userMenuButtonRenderer(final UserDetails userDetails) { … }

@Install(to = "userMenu", subject = "headerRenderer")
private Component userMenuHeaderRenderer(final UserDetails userDetails) { … }
```

Both start `if (!(userDetails instanceof User user)) return null;`, so a project
whose user class is not the entity silently renders nothing. The name helper
reads `firstName`/`lastName` and falls back to `username` — check your `User`
actually has those attributes before copying it.

## Step 4 — populate the initial layout

```xml
<initialLayout id="initialLayout" classNames="jmix-initial-layout">
    <div classNames="jmix-initial-layout-content">
        <h1 text="msg://applicationTitle.text" classNames="jmix-initial-layout-title"/>
        <image resource="public/images/logo.png" classNames="jmix-initial-layout-logo"/>
    </div>
</initialLayout>
```

The logo file belongs at `src/main/resources/META-INF/resources/public/images/`.
The initial layout renders **only when no view is open**, so it is invisible on
any deep link — navigate to `/` to see it.

## Step 5 — permit the public asset chain, or the logo 403s

The single loudest-looking, quietest-failing step. With the file in place and
served, Spring Security still denies it: the browser shows a broken-image box
and the server says nothing above DEBUG.

The scaffolded `<App>SecurityConfiguration` is an **empty class** — the filter
chain exists only as an example inside its javadoc. Every new Jmix project ships
it that way, so this is not damage from the upgrade.

```java
@Bean
@Order(JmixSecurityFilterChainOrder.CUSTOM)
SecurityFilterChain publicFilterChain(HttpSecurity http) throws Exception {
    http.securityMatcher("/public/**")
            .authorizeHttpRequests(authorize -> authorize.anyRequest().permitAll());
    return http.build();
}
```

This is a real security decision, not boilerplate: it serves everything under
`META-INF/resources/public/` to **anonymous** callers. That is required — the
logo has to load on the login view, before anyone authenticates — so keep that
directory to public branding assets and nothing else.

## Step 6 — define the message keys

- `applicationTitle.text` — already present from the 2.x project, reused by the
  initial-layout title.
- `actions.logout.text` — framework key, referenced as `msg:///…`.
- `userMenu.substituted` — **the scaffold references this key without defining
  it.** Add it yourself, unprefixed (no `<package>/` group), since the renderer
  calls `messages.getMessage(String)`, which is a plain global lookup.

`Messages.getMessage` "returns localized message **or the key** if the message
is not found", so a missing key renders as the literal string
`userMenu.substituted` in the UI. It surfaces only while a user is substituted,
which is exactly when nobody is looking.

## Verify — in a browser, logged in

Compile and IDE inspections pass on every defect in this skill. They prove
nothing. Start the app and check:

```bash
# Logged OUT, no session — the login view needs this to be 200, not 403
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" \
     http://localhost:8080/public/images/logo.png
```

```js
// The logo decoded, rather than rendering as a broken-image box
document.querySelector('.jmix-initial-layout-logo').naturalWidth   // not 0

// The user-menu classes resolve to real theme rules, not nothing
getComputedStyle(document.querySelector('.user-menu-button-content')).display  // 'grid'
!!document.querySelector('.user-menu-avatar')                                  // true

// No key leaked into the UI as literal text
document.body.innerText.match(/msg:\/\/|userMenu\.substituted/)                // null
```

Then open the user menu and confirm the avatar header and **Log out** item.

**`substituteUserMenuItem` is hidden when the user has no substitution
candidates configured. That is correct behaviour, not a failed port** — do not
"fix" it.

**An agent cannot reach any of this alone.** The main view needs an
authenticated session and an agent must not type passwords into the login form.
Run the `curl` check yourself, then ask the user to log in and run the rest.
Every app restart drops the session, so batch the browser checks into one pass.

## Forbidden

- Adding `userMenu` and keeping the drawer `<footer>` with `userIndicator` and
  the logout button — two logout controls.
- Copying the renderers while renaming any `user-menu-*` class, or setting the
  classes without installing the renderers.
- Shipping `<image resource="public/…">` without the `/public/**` filter chain,
  or concluding from the broken image that the file is missing — it is served,
  and denied.
- Widening the public chain past `/public/**`, or putting anything but public
  branding assets under `META-INF/resources/public/`.
- Calling `messages.getMessage("userMenu.substituted")` without defining the key,
  or defining it under a `<package>/` group.
- Judging the initial layout from a deep link — it renders only at `/`.
- Reporting the port verified from a compile, a green `clean test`, or the
  login view. None of them render the main view.
