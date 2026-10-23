# Jmix Agent Toolkit

Agent skills, guidelines and tools that teach AI coding agents the Jmix-specific patterns, mandatory rules and best practices for developing applications with the [Jmix framework](https://www.jmix.io/).

## Repository Structure

Each Jmix major version lives on its own branch: `v2` for Jmix 2, `v3` for Jmix 3, and so on. The default branch is the current stable major. A branch's `content/` folder holds:

- `guidelines-block.md`: a short block, delimited by `<!-- BEGIN jmix-agent-toolkit -->` / `<!-- END jmix-agent-toolkit -->` markers, that the installer merges into the project's agent guidelines file. It points the agent at the `jmix` skill.
- `skills/`: one folder per skill, each with a `SKILL.md` (instructions and rules for a specific Jmix feature) and optional subfolders with examples or other materials.

## Studio Installation

The simplest way is Jmix Studio 3.0+: run the **AI Agents Toolkit** action from the **Settings** menu of the **Jmix** tool window and follow the wizard.

## Quick CLI Installation

One command starts an interactive wizard with three steps: installing skills, adding guidelines, and registering the JetBrains, Context7 and Playwright MCP servers.

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.sh | bash
```

**Windows (PowerShell 5+):**

```powershell
Invoke-RestMethod https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.ps1 | Invoke-Expression
```

If the execution policy blocks the script, bypass it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod 'https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.ps1' | Invoke-Expression"
```

If `powershell.exe` itself is blocked by a corporate policy (`CreateProcess error=5, Access is denied`), use PowerShell 7 (`pwsh`):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod 'https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.ps1' | Invoke-Expression"
```

### Non-Interactive Subcommands

Each runs one step without the wizard. **CSV** is a comma-separated list (e.g. `claude,codex`) or a single value.

```bash
install.sh skills     [--scope global|local] [--claude=false]
install.sh agents-md  [--claude=false]
install.sh mcp        --servers CSV --agents CSV [--scope local|global] [--context7-key KEY]
install.sh mcp-jetbrains | mcp-context7 | playwright --agents CSV [--scope local|global]
                                     # mcp-context7 also takes [--context7-key KEY]
```

Piped from `curl`, pass the subcommand after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.sh | bash -s -- mcp --servers jetbrains,playwright --agents claude,codex
```

PowerShell takes the same subcommands and flags (e.g. `install.ps1 skills -Scope local -Claude:$false` to skip Claude Code). To run one straight from the URL:

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.ps1).Content)) mcp -Servers 'jetbrains,playwright' -Agents 'claude,codex'
```

Quote lists: unquoted, `claude,codex` is an array in PowerShell.

`skills` always installs the skills into `.agents/skills`, and `agents-md` always merges the guidelines into `AGENTS.md`: Codex, OpenCode, Junie, Cline, Cursor, GitHub Copilot, Gemini CLI and others read them there. Claude Code is included by default: each skill is linked into `.claude/skills`, and a new `CLAUDE.md` contains only `@AGENTS.md`, so the shared instructions have one copy. Existing `CLAUDE.md` files keep the current merge and backup rules; a file that already imports `AGENTS.md` is left untouched. Use `--claude=false` (`-Claude:$false`) to skip Claude Code.

The MCP subcommands take **agents**, each with its own config: `claude`, `codex`, `opencode`, `junie`, `cline`. `claude` also sets up [Claude Desktop](#claude-desktop) when it is installed. [Cline](#cline) has only a user config, which it gets whatever the `--scope`.

### Flags

| Flag (bash)               | Flag (PowerShell)      | Default | Meaning                                                                                                                                                                                                                                                                                                              |
|:--------------------------|:-----------------------|:--------|:---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--content-ref REF`       | `-ContentRef REF`      | `v2`    | Branch/ref whose `content/` is downloaded; it also names the global skills store. Studio passes its resolved toolkit branch.                                                                                                                                                                                         |
| `--source DIR`            | `-Source DIR`          | -       | Install from a local checkout of this repository instead of downloading (CI, offline use).                                                                                                                                                                                                                           |
| `--claude[=true\|false]`  | `-Claude`              | on      | `skills`, `agents-md`: set up Claude Code by default. Use `--claude=false` / `-Claude:$false` to skip `.claude/skills` links and `CLAUDE.md`. `.agents/skills` and `AGENTS.md` are always installed. |
| `--agents CSV`            | `-Agents CSV`          | -       | MCP subcommands: `claude`, `codex`, `opencode`, `junie`, `cline`. Required.                                                                                                                                                                                                                                          |
| `--servers CSV`           | `-Servers CSV`         | -       | `mcp`: `jetbrains`, `context7`, `playwright`. Required.                                                                                                                                                                                                                                                              |
| `--scope global\|local`   | `-Scope global\|local` | global  | `skills`: install into the user home or the current project, see **Skills store** below.                                                                                                                                                                                                                             |
| `--scope local\|global`   | `-Scope local\|global` | local   | MCP subcommands: write the project files in the current directory or each agent's user config. Claude Desktop and Cline have only a user config.                                                                                                                                                                     |
| `--context7-key K`        | `-Context7Key K`       | prompt  | `mcp`, `mcp-context7`: Context7 API key (letters, digits, `.`, `_`, `-`); `skip` leaves Context7 out. Never printed. At `local` scope it goes into the project files: keep them out of version control.                                                                                                              |
| `--backup-existing-files` | `-BackupExistingFiles` | off     | Rename overwritten files/dirs to `<name>.bak` (`.bak1`, `.bak2`, ... when taken) instead of deleting them. Not for guidelines files: they are merged, and backed up (with or without this flag) only when the toolkit rewrites content it does not own: an older toolkit's file, or your own file getting the block. |
| `--verbose`, `--debug`    | `-Verbose`             | off     | Print diagnostics (OS, PATH, resolved paths, tool versions).                                                                                                                                                                                                                                                         |

**Environment:** `JMIX_IDE_MCP_PORT` sets the port of the IntelliJ IDEA MCP server (default `64342`), e.g. `curl ... | JMIX_IDE_MCP_PORT=64343 bash -s -- mcp-jetbrains --agents claude`. `CLINE_MCP_SETTINGS_PATH`, `CLINE_DATA_DIR` and `CLINE_DIR` move Cline's MCP config, as they do for Cline itself.

**Skills store:** the skills are copied into a store, and each skill folder is linked into `.agents/skills` (unless that dir is the store) and, unless `--claude=false`, into `.claude/skills`, next to any other skills there.
- **Global:** store at `~/.agents/.jmix/skills/<ref>/` (the `--content-ref`, e.g. `v2`), linked into `~/.agents/skills` and, unless `--claude=false`, into `~/.claude/skills`.
- **Local:** the store is `<project>/.agents/skills/` itself, so the skills are real folders there. Each skill is linked into `<project>/.claude/skills` unless `--claude=false`. With `--backup-existing-files`, replaced skill folders go to `<project>/.agents/.jmix/backups/`, where no agent reads them as skills.

**Upgrading from an older local install:** older versions kept the local store in `<project>/.skills/`. A re-run moves the skills into `.agents/skills`, re-points the links into `.skills` in `.claude/skills` (and in any other `<project>/.*/skills` you linked the same way), deletes the toolkit's skills from `.skills`, moves any other `jmix*` entry there (a retired skill or your own) to `.agents/.jmix/backups/`, and deletes `.skills` when nothing else is left. A `.skills` that is a link is left alone. One that a skills dir links to (e.g. `.claude/skills -> ../.skills`) is kept: behind `.agents/skills` it stays the store, behind any other dir its Jmix skills become links to `.agents/skills`. If the old layout is committed, git shows `.skills` deleted, the `.agents/skills` entries changed from symlinks to folders and the `.claude/skills` links re-pointed.

> The installer writes MCP servers straight into each agent's config file (see [MCP Servers](#3-mcp-servers)), keeping its other servers and settings; only Claude CLI at `global` scope goes through `claude mcp add`. A file that is already up to date is not rewritten. On macOS/Linux, merging into an existing JSON config file needs `jq` or `node`; a new file is written without them. Servers started through `npx` need Node.js 20+ when the agent starts them, not at install time.

## Manual Installation

To skip the script, check out the branch for your Jmix major and take the files from its `content/` folder.

### 1. Project Guidelines

The guidelines live in the `jmix` skill; the project's agent guidelines file gets only a short block that points the agent at it. Add the content of `guidelines-block.md` to that file, or create the file with just the block. Keep the `<!-- BEGIN jmix-agent-toolkit -->` / `<!-- END jmix-agent-toolkit -->` markers: a later installer run replaces only the region between them, so keep your own instructions outside them. In an `AGENTS.md`, put the block at the top: Codex reads only the first 32 KiB.

- [Claude CLI](https://code.claude.com/docs): `CLAUDE.md` in the project root.
- [Codex](https://developers.openai.com/codex/cli): `AGENTS.md` in the project root. If an `AGENTS.override.md` sits next to it, Codex reads that file instead; copy the block into it.
- [OpenCode](https://opencode.ai/docs): `AGENTS.md` in the project root.
- [Junie](https://www.jetbrains.com/junie): `AGENTS.md` in the project root. If your project has `.junie/AGENTS.md`, Junie reads only that file; add the block there (the installer does not).
- [Cline](https://docs.cline.bot): `AGENTS.md` in the project root (it does not read `CLAUDE.md`).

A full `AGENTS.md` or `CLAUDE.md` from an earlier toolkit version is replaced, not extended: delete its toolkit content and paste in the block. The installer does this itself and keeps the old file as `<name>.bak`.

### 2. Agent Skills

`skills/` holds the skills for Jmix features (entities, UI views, data access, etc.). Copy or symlink **each** skill folder so it sits directly inside the agent's skills folder in the project or your home directory (e.g. `~/.claude/skills/jmix-create-entity/`): agents do not scan nested subfolders, so do not link the whole `skills/` directory as one entry. Leave other (non-Jmix) skills in that folder alone.

| Agent                         | Project Skills Folder Path | Global Skills Folder Path |
|:------------------------------|:---------------------------|:--------------------------|
| Claude CLI                    | `.claude/skills/`          | `~/.claude/skills/`       |
| Codex, OpenCode, Junie, Cline | `.agents/skills/`          | `~/.agents/skills/`       |

#### Example

Re-run after pulling new skills: `ln -sfn` refreshes existing links and leaves other skills untouched:
```bash
mkdir -p ~/.claude/skills
# run from a checkout of your major's branch (v2, v3, ...)
for skill in /path/to/jmix-agent-toolkit/content/skills/*/; do
    ln -sfn "$skill" ~/.claude/skills/"$(basename "$skill")"
done
```

To copy instead (the skills then survive deleting the clone), replace the `ln -sfn` line with `cp -R "${skill%/}" ~/.claude/skills/`. Keep the `%/`: on macOS, `cp -R` with a trailing slash copies the folder's contents, not the folder.

#### Agent Conventions Summary

| Agent      | Project Guidelines     | Home Directory Base   |
|:-----------|:-----------------------|:----------------------|
| Claude CLI | `CLAUDE.md`            | `~/.claude/`          |
| Codex      | `AGENTS.md`            | `~/.codex/`           |
| OpenCode   | `AGENTS.md`            | `~/.config/opencode/` |
| Junie      | `AGENTS.md`            | `~/.junie/`           |
| Cline      | `AGENTS.md`            | `~/.cline/`           |

### 3. MCP Servers

Two MCP servers help AI agents build Jmix apps:

- JetBrains (**highly recommended**): lets an external agent talk to a running IntelliJ IDEA to use its code analysis and inspections.

- Context7 (optional): gives the agent docs and code examples from official sources.

The installer registers them and the [Playwright](#4-playwright-tests) server in the project files (`--scope local`, the default) or in each agent's user config (`--scope global`, serves every project). Project servers need a confirmation: Claude Code asks to approve the servers in `.mcp.json`, and Codex reads `.codex/config.toml` only in trusted projects (its desktop app ignores project servers). At user level, Claude CLI is registered through `claude mcp add --scope user`, so the installer needs `claude` on PATH, in `~/.local/bin` or in `~/.claude/local`, and skips Claude CLI without it.

Codex merges the user config with the `.codex/config.toml` of the current directory and its parents up to the git root (only the current directory outside a repository). The installer writes one of these files and only reads the others; the step fails and names the file when another one defines the same server with the other transport (`url` vs `command`, which Codex cannot merge) or through inline tables or dotted keys. Other projects are not checked: if one defines the server with the other transport in its `.codex/config.toml`, remove that table. In the file it writes, the installer edits only explicit `[mcp_servers.<name>]` tables; a file with triple-quoted strings, or with the server defined through inline tables or dotted keys, is left untouched and needs manual configuration.

| Agent                                          | Project file          | User file                                                             | Servers key            |
|:-----------------------------------------------|:----------------------|:----------------------------------------------------------------------|:-----------------------|
| Claude CLI                                     | `.mcp.json`           | `~/.claude.json`, through `claude mcp add --scope user`               | `mcpServers`           |
| Codex                                          | `.codex/config.toml`  | `~/.codex/config.toml` (`$CODEX_HOME`)                                | `[mcp_servers.<name>]` |
| OpenCode                                       | `opencode.json`       | `~/.config/opencode/opencode.json` (`$XDG_CONFIG_HOME`)               | `mcp`                  |
| Junie                                          | `.junie/mcp/mcp.json` | `~/.junie/mcp/mcp.json` (`$JUNIE_HOME` for the Junie CLI)             | `mcpServers`           |
| Cline                                          | -                     | `~/.cline/data/settings/cline_mcp_settings.json`, see [Cline](#cline) | `mcpServers`           |
| Claude Desktop (with `claude`, when installed) | -                     | `claude_desktop_config.json`, see [Claude Desktop](#claude-desktop)   | `mcpServers`           |

To run the JetBrains MCP server in IntelliJ IDEA, go to **Settings → Tools → MCP Server** and select **Enable MCP Server ✓**, then keep your project open in the IDE. The server listens on `127.0.0.1`, port `64342` by default. The endpoint depends on the IDE version:

- IntelliJ IDEA 2026.1+: Streamable HTTP at `http://127.0.0.1:64342/stream`.
- IntelliJ IDEA 2025.2 / 2025.3: SSE at `http://127.0.0.1:64342/sse`.

The installer probes `/stream` to choose the endpoint. If the IDE does not answer, it assumes 2026.1+, so on 2025.x run the step with the IDE open and its MCP server enabled. Context7 uses the remote endpoint `https://mcp.context7.com/mcp` with the header `Authorization: Bearer YOUR_API_KEY`. Junie and Claude Desktop use the stdio package `@upstash/context7-mcp` instead, with the key in `CONTEXT7_API_KEY`.

Below are the entries the installer writes for each agent. Merge them into the existing project or user file.

#### Claude CLI

For the project, use `--scope project` instead of `--scope user`: it writes `.mcp.json`.

- JetBrains MCP:
    ```bash
    claude mcp add --scope user --transport http jetbrains http://127.0.0.1:64342/stream
    # IntelliJ IDEA 2025.2/2025.3:
    claude mcp add --scope user --transport sse jetbrains http://127.0.0.1:64342/sse
    ```

- Context7 MCP. Keep `--header` after the URL: it takes several values and would swallow any arguments after it.
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

- Context7 MCP, `.codex/config.toml` or `~/.codex/config.toml`:
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

- Context7 MCP, `opencode.json` or `~/.config/opencode/opencode.json`:
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

- JetBrains MCP: not needed, so the installer skips it. Junie runs inside IntelliJ IDEA and already has native access to the IDE.

- Context7 MCP, `.junie/mcp/mcp.json` or `~/.junie/mcp/mcp.json`:
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

#### Cline

The Cline VS Code extension, JetBrains plugin and CLI share one user-level file, `~/.cline/data/settings/cline_mcp_settings.json` (`%USERPROFILE%\.cline\data\settings\` on Windows). `CLINE_MCP_SETTINGS_PATH` (the file), `CLINE_DATA_DIR` (instead of `~/.cline/data`) or `CLINE_DIR` (instead of `~/.cline`) move it. Cline has no project MCP config, so `cline` in an MCP step writes this file whatever the `--scope`. The extension and the plugin pick up a change on their own; the CLI reads the file when a session starts.

Cline checks the whole file: with one entry it does not accept, such as Claude Code's `"type": "http"`, it loads none of the servers. Spell `type` as `streamableHttp`, `sse` or `stdio`; a `url` entry without `type` is taken as SSE.

```json
{
  "mcpServers": {
    "jetbrains": {
      "type": "streamableHttp",
      "url": "http://127.0.0.1:64342/stream"
    },
    "context7": {
      "type": "streamableHttp",
      "url": "https://mcp.context7.com/mcp",
      "headers": { "Authorization": "Bearer YOUR_API_KEY" }
    }
  }
}
```

On IntelliJ IDEA 2025.2/2025.3 the JetBrains entry is `{ "type": "sse", "url": "http://127.0.0.1:64342/sse" }`. If the Cline JetBrains plugin already lists the IDE's MCP server on its own, delete the `jetbrains` entry so its tools are not offered twice. VS Code windows that still run Cline's legacy build read `<VS Code user dir>/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` instead; copy the entries there if Cline in VS Code does not show them.

#### Claude Desktop

Claude Desktop reads MCP servers from a user-level `claude_desktop_config.json`:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`. The Store (MSIX) build reads its own copy under `%LOCALAPPDATA%\Packages\*Claude_*\LocalCache\Roaming\Claude`. The installer updates every copy that exists.
- Linux: `~/.config/Claude/claude_desktop_config.json` (`$XDG_CONFIG_HOME`)

It is not a separate agent. When `claude` is selected in an MCP step, the installer also updates this file, whatever the `--scope`, if Claude Desktop is installed, i.e. its config folder exists. Start Claude Desktop once before running the installer. Claude Desktop accepts only stdio entries, so JetBrains MCP always goes through the `mcp-remote` bridge to `/sse`.

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

[Playwright](https://playwright.dev) lets the agent verify a running application in the browser, from navigation to complex UI behavior. The toolkit registers the [Playwright MCP server](https://github.com/microsoft/playwright-mcp) (`@playwright/mcp`), which the agent starts through `npx` (Node.js 20+).

Add the server to the files listed in [MCP Servers](#3-mcp-servers):

- Claude CLI: `claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest`.

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

- Junie, Cline and Claude Desktop:
    ```json
    {
      "mcpServers": {
        "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"] }
      }
    }
    ```

Then give the agent instructions like:

> Run the app and use Playwright MCP to log in and test all created views
