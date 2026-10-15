# Jmix Agent Toolkit

This repository provides a collection of agent skills, guidelines and tools designed to help AI coding agents develop applications using the [Jmix framework](https://www.jmix.io/) effectively.

The AI agent will use these resources to understand Jmix-specific patterns, mandatory rules, and best practices.

## Repository Structure

Each Jmix major version lives on its own branch: `v2` for Jmix 2, `v3` for Jmix 3, and so on. The repository default branch is the current stable major. Each branch holds a single `content/` folder:

- `content/` contains the guidelines for that branch's Jmix version.
  - `guidelines-block.md`: A short block, delimited by `<!-- BEGIN jmix-agent-toolkit -->` / `<!-- END jmix-agent-toolkit -->` markers, that the installer merges into the project's own agent guidelines file. It points the agent at the `jmix` skill.
  - `skills/`: A collection of folders, each containing:
      - `SKILL.md`: Detailed instructions and rules for the agent regarding a specific Jmix feature.
      - Optional subdirectories with examples or other materials.

## Studio Installation

The simplest way to install agent toolkit to your project is to use Jmix Studio 3.0+. 

Execute the **AI Agents Toolkit** action in the **Settings** menu of the **Jmix** tool window and follow the steps of the GUI interactive wizard.

## Quick CLI Installation

A single command launches an interactive wizard that walks through every setup step:
installing skills, adding guidelines, and registering the JetBrains, Context7 and Playwright MCP servers.
Playwright is registered as the [`@playwright/mcp`](https://github.com/microsoft/playwright-mcp) server; the wizard no longer installs the `playwright-cli` skill.

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v3/install.sh | bash
```

**Windows (PowerShell 5+):**

```powershell
Invoke-RestMethod https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v3/install.ps1 | Invoke-Expression
```

If PowerShell blocks the script because of its execution policy, run it explicitly with the policy bypassed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod 'https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v3/install.ps1' | Invoke-Expression"
```

If `powershell.exe` itself is blocked by a corporate policy (`CreateProcess error=5, Access is denied`), use PowerShell 7 (`pwsh`):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod 'https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v3/install.ps1' | Invoke-Expression"
```

> In Jmix Studio plugin, the same wizard is available from the **Jmix AI Agents Toolkit** action.

### Non-Interactive Subcommands

Use these to run a single step without the wizard. Every subcommand takes the
same `--agents CSV` flag:

```bash
install.sh skills        --agents CSV   [--scope global|local]
install.sh agents-md     --agents CSV
install.sh mcp-jetbrains --agents CSV   [--scope local|global]
install.sh mcp-context7  --agents CSV   [--context7-key KEY]
install.sh playwright    --agents CSV   [--scope local|global]
```

Piped from `curl`, pass the subcommand after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v3/install.sh | bash -s -- playwright --agents claude,codex
```

PowerShell mirrors the same shape: `install.ps1 skills -Agents 'claude,codex'`, `install.ps1 mcp-jetbrains -Agents 'claude,codex' -Scope global`, `install.ps1 mcp-context7 -Agents claude -Context7Key KEY`, `install.ps1 playwright -Agents 'claude,codex'`, etc. Quote a list: unquoted, `claude,codex` is an array in PowerShell.

**CSV** = comma-separated agent list (e.g. `claude,codex`) or a single value (e.g. `claude`). Valid agents: `claude`, `codex`, `opencode`, `junie`. The MCP subcommands (`mcp-jetbrains`, `mcp-context7`, `playwright`) also accept `claude-desktop`.

Context7 is always registered at user level, so the API key never lands in project files.

### Flags

| Flag (bash)               | Flag (PowerShell)      | Default | Meaning                                                                                                                                                                                                   |
|:--------------------------|:-----------------------|:--------|:----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--content-ref REF`       | `-ContentRef REF`      | `v3`    | Repository branch/ref to download and use. Studio supplies its resolved toolkit branch.                                                                                                                   |
| `--source DIR`            | `-Source DIR`          | -       | Install from a local checkout of this repository instead of downloading. Skips the network. Mainly for CI and offline use.                                                                                |
| `--agents CSV`            | `-Agents CSV`          | -       | Comma-separated agents. Required by every subcommand.                                                                                                                                                     |
| `--scope global\|local`   | `-Scope global\|local` | global  | `skills`. `global` installs the store under `~/.agents/.jmix/skills/v<major>`; `local` installs the store at `<project>/.skills`. Agent dirs are symlinked to the store.                                  |
| `--scope local\|global`   | `-Scope local\|global` | local   | `mcp-jetbrains`, `playwright`. `local` writes the project config files in the current directory; `global` writes each agent's user config (see [MCP Servers](#3-mcp-servers)). Claude Desktop has only a user config and ignores the scope. |
| `--context7-key K`        | `-Context7Key K`       | prompt  | Context7 API key (letters, digits, `.`, `_`, `-`). Prompted interactively when omitted. Never printed.                                                                                                    |
| `--backup-existing-files` | `-BackupExistingFiles` | off     | Rename overwritten files/dirs to a deduped `<name>.bak` instead of deleting them. Project guidelines (`CLAUDE.md` / `AGENTS.md`) are merged rather than overwritten and are not covered by this flag: a backup is made only when the toolkit rewrites content it does not own — replacing a guidelines file an older toolkit version installed, or adding the block to your own file. Replacing only the marked region never makes a backup, and an already-current file is left untouched. |
| `--verbose`, `--debug`    | `-Verbose`             | off     | Print extra diagnostic output (OS, PATH, resolved paths, tool versions) for troubleshooting.                                                                                                              |

**Environment:** `JMIX_IDE_MCP_PORT` sets the port of the IntelliJ IDEA MCP server for `mcp-jetbrains` (default `64342`), e.g. `curl ... | JMIX_IDE_MCP_PORT=64343 bash -s -- mcp-jetbrains --agents claude`.

**Skills storages:**
- **Global:** store at `~/.agents/.jmix/skills/v<major>/` (e.g. `v3`); each skill folder (`jmix` and `jmix-*`) symlinked into `~/.claude/skills` (Claude CLI) and `~/.agents/skills` (Codex, OpenCode, Junie).
- **Local:** store at `<project>/.skills/`; each skill folder (`jmix` and `jmix-*`) symlinked into `<project>/.agents/skills` and `<project>/.claude/skills`.
- Earlier versions also linked the skills into `.junie/skills`. Junie reads `.agents/skills`, and its CLI reads `~/.junie/skills` first, so the installer removes those old links (only links into a toolkit store).

> The automatic installer covers skills (installed globally or into the project), project guidelines, and registration of the JetBrains, Context7 and Playwright MCP servers. It writes the servers straight into each agent's config file (see [MCP Servers](#3-mcp-servers)), keeping the other servers and settings there; only Claude CLI at user level goes through `claude mcp add`. A file that is already up to date is not rewritten. On macOS/Linux, merging into an existing JSON config file needs `jq` or `node`; a new file is written without them. Servers started through `npx` need Node.js 20+ when the agent starts them, not at install time.

## Manual Installation

If you prefer not to run the script, follow these steps. Check out the branch for your Jmix major and take the files from its `content/` folder.

### 1. Project Guidelines

The toolkit no longer installs a full guidelines file. Instead it adds a short block that points the agent at the `jmix` skill, which carries the guidelines themselves.

Copy the content of `guidelines-block.md` into your project's agent guidelines file, keeping the `<!-- BEGIN jmix-agent-toolkit -->` / `<!-- END jmix-agent-toolkit -->` markers. If the file does not exist yet, create it with just that block. If it does, add the block — everything you wrote stays. Put it at the top of an `AGENTS.md`: Codex reads only the first 32 KiB of it.

- [Claude CLI](https://code.claude.com/docs): `CLAUDE.md` in the project root.
- [Codex](https://developers.openai.com/codex/cli): `AGENTS.md` in the project root.
- [OpenCode](https://opencode.ai/docs): `AGENTS.md` in the project root.
- [Junie](https://www.jetbrains.com/junie): `AGENTS.md` in the project root. If your project has `.junie/AGENTS.md`, Junie reads only that file; add the block there yourself.

The markers let the installer update the block in place on a later run without touching the rest of the file. Keep your own instructions outside them.

If your project still has a full `AGENTS.md` or `CLAUDE.md` from an earlier version of this toolkit, the installer detects it, backs it up as `<name>.bak`, and replaces it with the block. Doing it by hand, delete the old toolkit content and paste in the block.

### 2. Agent Skills

The `skills/` directory contains specialized knowledge for developing various Jmix features (entities, UI views, data access, etc.). These should be made available to the agent globally or per-project.

Each skill must sit **directly** inside the agent's skills folder (e.g. `~/.claude/skills/jmix-create-entity/`) — agents do not scan nested subfolders, so the skills must be linked **individually**. Do not symlink the whole `skills/` directory as a single entry, and note that the folder normally holds other (non-Jmix) skills that must be left in place.

Copy or symlink each folder from `skills/` into the folder recognized by your agent in your project or user home directory:

| Agent      | Project Skills Folder Path | Global Skills Folder Path |
|:-----------|:---------------------------|:--------------------------|
| Claude CLI | `.claude/skills/`          | `~/.claude/skills/`       |
| Codex      | `.agents/skills/`          | `~/.agents/skills/`       |
| OpenCode   | `.agents/skills/`          | `~/.agents/skills/`       |
| Junie      | `.agents/skills/`          | `~/.agents/skills/`       |

#### Example

Symlink each skill individually. This is idempotent — re-run it after pulling new skills, and it leaves any non-Jmix skills in the folder untouched:
```bash
mkdir -p ~/.claude/skills
# run from a checkout of your major's branch (v2, v3, ...)
for skill in /path/to/jmix-agent-toolkit/content/skills/*/; do
    ln -sfn "$skill" ~/.claude/skills/"$(basename "$skill")"
done
```

`ln -sfn` refreshes an existing link in place, so re-running picks up newly added skills without disturbing the rest of the folder. To copy instead of symlinking (so the skills survive deleting this clone), replace the `ln -sfn` line with `cp -R "$skill" ~/.claude/skills/`.

#### Agent Conventions Summary

| Agent      | Project Guidelines     | Home Directory Base   |
|:-----------|:-----------------------|:----------------------|
| Claude CLI | `CLAUDE.md`            | `~/.claude/`          |
| Codex      | `AGENTS.md`            | `~/.codex/`           |
| OpenCode   | `AGENTS.md`            | `~/.config/opencode/` |
| Junie      | `AGENTS.md`            | `~/.junie/`           |

### 3. MCP Servers

The following two MCP servers help AI agents to build Jmix apps:

- JetBrains (**highly recommended**): lets an external agent talk to a running IntelliJ IDEA to leverage code analysis and inspections.

- Context7 (optional): gives the agent docs and code examples from official sources.

The installer writes them (and the [Playwright](#4-playwright-tests) server) into these files. Project files are used with `--scope local` (the default), user files with `--scope global`; Context7 always goes to the user file. Claude CLI at user level needs `claude` on PATH; without it the installer skips that agent.

| Agent          | Project file          | User file                                                        | Servers key            |
|:---------------|:----------------------|:-----------------------------------------------------------------|:-----------------------|
| Claude CLI     | `.mcp.json`           | `~/.claude.json`, through `claude mcp add --scope user`          | `mcpServers`           |
| Codex          | `.codex/config.toml`  | `~/.codex/config.toml` (`$CODEX_HOME`)                           | `[mcp_servers.<name>]` |
| OpenCode       | `opencode.json`       | `~/.config/opencode/opencode.json` (`$XDG_CONFIG_HOME`)          | `mcp`                  |
| Junie          | `.junie/mcp/mcp.json` | `~/.junie/mcp/mcp.json` (`$JUNIE_HOME`, Junie CLI only)          | `mcpServers`           |
| Claude Desktop | -                     | `claude_desktop_config.json`, see [Claude Desktop](#claude-desktop) | `mcpServers`     |

To run the JetBrains MCP server in IntelliJ IDEA, go to **Settings → Tools → MCP Server** and select **Enable MCP Server ✓**. When working with a project, keep it open in the IDE. The server listens on `127.0.0.1`, port `64342` by default. Its endpoint depends on the IDE version:

- IntelliJ IDEA 2026.1+: Streamable HTTP at `http://127.0.0.1:64342/stream`.
- IntelliJ IDEA 2025.2 / 2025.3: SSE at `http://127.0.0.1:64342/sse`. Codex has no SSE transport and connects through the stdio bridge `npx -y mcp-remote http://127.0.0.1:64342/sse --transport sse-only`.

The installer picks the endpoint by probing `/stream`. Context7 uses the remote endpoint `https://mcp.context7.com/mcp` with the header `Authorization: Bearer YOUR_API_KEY`, or, for Junie and Claude Desktop, the stdio package `@upstash/context7-mcp` with the key in `CONTEXT7_API_KEY`.

Below are the entries the installer writes, per agent. Merge them into the existing file.

#### Claude CLI

- JetBrains MCP, project `.mcp.json`:
    ```json
    {
      "mcpServers": {
        "jetbrains": { "type": "http", "url": "http://127.0.0.1:64342/stream" }
      }
    }
    ```
    On IntelliJ IDEA 2025.2/2025.3 use `{ "type": "sse", "url": "http://127.0.0.1:64342/sse" }`. At user level:
    ```bash
    claude mcp add --scope user --transport http jetbrains http://127.0.0.1:64342/stream
    # IntelliJ IDEA 2025.2/2025.3:
    claude mcp add --scope user --transport sse jetbrains http://127.0.0.1:64342/sse
    ```

- Context7 MCP (user level). Keep `--header` after the URL: it takes several values and would swallow the arguments after it.
    ```bash
    claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp --header "Authorization: Bearer YOUR_API_KEY"
    ```

#### Codex

- JetBrains MCP, `.codex/config.toml` or `~/.codex/config.toml`:
    ```toml
    [mcp_servers.jetbrains]
    url = "http://127.0.0.1:64342/stream"
    ```
    Codex has no SSE transport, so on IntelliJ IDEA 2025.2/2025.3 use the stdio bridge:
    ```toml
    [mcp_servers.jetbrains]
    command = "npx"
    args = ["-y", "mcp-remote", "http://127.0.0.1:64342/sse", "--transport", "sse-only"]
    startup_timeout_sec = 60
    ```
    The stdio command from **Copy Stdio Config** (**Settings → Tools → MCP Server**, **Manual Client Configuration**) works too.

- Context7 MCP, `~/.codex/config.toml`:
    ```toml
    [mcp_servers.context7]
    url = "https://mcp.context7.com/mcp"
    http_headers = { Authorization = "Bearer YOUR_API_KEY" }
    ```

#### OpenCode

- JetBrains MCP, `opencode.json` or `~/.config/opencode/opencode.json` (on IntelliJ IDEA 2025.2/2025.3 use the `/sse` URL):
    ```json
    {
      "mcp": {
        "jetbrains": {
          "type": "remote",
          "url": "http://127.0.0.1:64342/stream",
          "enabled": true
        }
      }
    }
    ```

- Context7 MCP, `~/.config/opencode/opencode.json`:
    ```json
    {
      "mcp": {
        "context7": {
          "type": "remote",
          "url": "https://mcp.context7.com/mcp",
          "headers": { "Authorization": "Bearer YOUR_API_KEY" },
          "enabled": true
        }
      }
    }
    ```

#### Junie

- JetBrains MCP: not required. Junie runs inside the IntelliJ and already has native access to the IDE features.

- Context7 MCP, `~/.junie/mcp/mcp.json`:
    ```json
    {
      "mcpServers": {
        "context7": {
          "command": "npx",
          "args": ["-y", "@upstash/context7-mcp"],
          "env": { "CONTEXT7_API_KEY": "YOUR_API_KEY" }
        }
      }
    }
    ```

#### Claude Desktop

Claude Desktop reads MCP servers from a user-level `claude_desktop_config.json`:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json` (MSIX installs may use `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude` instead)
- Linux: `~/.config/Claude/claude_desktop_config.json`

It takes only stdio entries, so the installer always connects JetBrains MCP through the `mcp-remote` bridge to `/sse`. The installer skips Claude Desktop when its config folder does not exist; start Claude Desktop once first.

```json
{
  "mcpServers": {
    "jetbrains": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:64342/sse", "--transport", "sse-only"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"],
      "env": { "CONTEXT7_API_KEY": "YOUR_API_KEY" }
    }
  }
}
```

After a change, quit Claude Desktop completely (not just its window) and start it again.

### 4. Playwright Tests

[Playwright](https://playwright.dev) integration provides AI agents with the ability to perform UI verification on a running application. This allows the agent to test navigation and complex UI behaviors directly in the browser.

The toolkit registers the [Playwright MCP server](https://github.com/microsoft/playwright-mcp) (`@playwright/mcp`), started by the agent through `npx` (Node.js 20+). It replaces the `playwright-cli` skill installed by earlier versions: MCP servers run outside Codex's sandbox, where the CLI skill could not launch a browser or reach the app on `localhost`, and no global binary has to be installed. The installer removes the old `playwright-cli` skill links from `~/.claude/skills`, `~/.agents/skills` and `~/.junie/skills` and deletes its store `~/.agents/.playwright`.

Add the server to the files listed in [MCP Servers](#3-mcp-servers), project or user level:

- Claude CLI, `.mcp.json`:
    ```json
    {
      "mcpServers": {
        "playwright": { "type": "stdio", "command": "npx", "args": ["-y", "@playwright/mcp@latest"] }
      }
    }
    ```
    At user level: `claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest`.

- Codex (the first `npx` download can outlast the default startup timeout):
    ```toml
    [mcp_servers.playwright]
    command = "npx"
    args = ["-y", "@playwright/mcp@latest"]
    startup_timeout_sec = 60
    ```

- OpenCode:
    ```json
    {
      "mcp": {
        "playwright": { "type": "local", "command": ["npx", "-y", "@playwright/mcp@latest"], "enabled": true }
      }
    }
    ```

- Junie and Claude Desktop:
    ```json
    {
      "mcpServers": {
        "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"] }
      }
    }
    ```

Once set up, you can give the agent instructions like:

> Run the app and use Playwright MCP to log in and test all created views