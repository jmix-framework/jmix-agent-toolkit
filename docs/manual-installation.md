# Manual Installation

To skip the script, check out the branch for your Jmix major and take its `skills/` folder and `content/guidelines-block.md`.

## 1. Project Guidelines

The guidelines live in the `jmix` skill; the project's agent guidelines file gets only a short block that points the agent at it. Add the content of `guidelines-block.md` to that file, or create the file with just the block. Keep the `<!-- BEGIN jmix-agent-toolkit -->` / `<!-- END jmix-agent-toolkit -->` markers: a later installer run replaces only the region between them, so keep your own instructions outside them. In an `AGENTS.md`, put the block at the top: Codex reads only the first 32 KiB.

- [Claude Code](https://code.claude.com/docs): `CLAUDE.md` in the project root.
- [Codex](https://developers.openai.com/codex/cli): `AGENTS.md` in the project root. If an `AGENTS.override.md` sits next to it, Codex reads that file instead; copy the block into it.
- [OpenCode](https://opencode.ai/docs): `AGENTS.md` in the project root.
- [Junie](https://www.jetbrains.com/junie): `AGENTS.md` in the project root. If your project has `.junie/AGENTS.md`, Junie reads only that file; add the block there (the installer does not).
- [Cline](https://docs.cline.bot): `AGENTS.md` in the project root (it does not read `CLAUDE.md`).

A full `AGENTS.md` or `CLAUDE.md` from an earlier toolkit version is replaced, not extended: delete its toolkit content and paste in the block. The installer does this itself and keeps the old file as `<name>.bak`.

## 2. Agent Skills

`skills/` holds the skills for Jmix features (entities, UI views, data access, etc.). Copy or symlink **each** skill folder so it sits directly inside the agent's skills folder in the project or your home directory (e.g. `~/.claude/skills/jmix-create-entity/`): agents do not scan nested subfolders, so do not link the whole `skills/` directory as one entry. Leave other (non-Jmix) skills in that folder alone.

| Agent                         | Project Skills Folder Path | Global Skills Folder Path |
|:------------------------------|:---------------------------|:--------------------------|
| Claude Code                   | `.claude/skills/`          | `~/.claude/skills/`       |
| Codex, OpenCode, Junie, Cline | `.agents/skills/`          | `~/.agents/skills/`       |

### Example

Re-run after pulling new skills: `ln -sfn` refreshes existing links and leaves other skills untouched:
```bash
mkdir -p ~/.claude/skills
# run from a checkout of your major's branch (v2, v3, ...)
for skill in /path/to/jmix-agent-toolkit/skills/*/; do
    ln -sfn "$skill" ~/.claude/skills/"$(basename "$skill")"
done
```

To copy instead (the skills then survive deleting the clone), replace the `ln -sfn` line with `cp -R "${skill%/}" ~/.claude/skills/`. Keep the `%/`: on macOS, `cp -R` with a trailing slash copies the folder's contents, not the folder.

## 3. MCP Servers

Three MCP servers help AI agents build Jmix apps:

- JetBrains (**highly recommended**): lets an external agent talk to a running IntelliJ IDEA to use its code analysis and inspections.

- Context7 (optional): gives the agent docs and code examples from official sources.

- Jmix Docs (optional): Jmix documentation, Java API and UI samples.

The installer registers them and the [Playwright](#4-playwright-tests) server in the project files (`--scope local`, the default) or in each agent's user config (`--scope global`, serves every project). Project servers need a confirmation: Claude Code asks to approve the servers in `.mcp.json`, and Codex reads `.codex/config.toml` only in trusted projects (its desktop app ignores project servers). At user level, Claude Code is registered through `claude mcp add --scope user`, so the installer needs `claude` on PATH, in `~/.local/bin` or in `~/.claude/local`, and skips Claude Code without it.

| Agent                                          | Project file          | User file                                                             | Servers key            |
|:-----------------------------------------------|:----------------------|:----------------------------------------------------------------------|:-----------------------|
| Claude Code                                    | `.mcp.json`           | `~/.claude.json`, through `claude mcp add --scope user`               | `mcpServers`           |
| Codex                                          | `.codex/config.toml`  | `~/.codex/config.toml` (`$CODEX_HOME`)                                | `[mcp_servers.<name>]` |
| OpenCode                                       | `opencode.json`       | `~/.config/opencode/opencode.json` (`$XDG_CONFIG_HOME`)               | `mcp`                  |
| Junie                                          | `.junie/mcp/mcp.json` | `~/.junie/mcp/mcp.json` (`$JUNIE_HOME` for the Junie CLI)             | `mcpServers`           |
| Cline                                          | -                     | `~/.cline/data/settings/cline_mcp_settings.json`, see [Cline](#cline) | `mcpServers`           |
| Claude Desktop (with `claude`, when installed) | -                     | `claude_desktop_config.json`, see [Claude Desktop](#claude-desktop)   | `mcpServers`           |

To run the JetBrains MCP server in IntelliJ IDEA, go to **Settings → Tools → MCP Server** and select **Enable MCP Server ✓**, then keep your project open in the IDE. The server listens on `127.0.0.1`, port `64342` by default. The endpoint depends on the IDE version:

- IntelliJ IDEA 2026.1+: Streamable HTTP at `http://127.0.0.1:64342/stream`.
- IntelliJ IDEA 2025.2 / 2025.3: SSE at `http://127.0.0.1:64342/sse`.

The installer probes `/stream` to choose the endpoint. If the IDE does not answer, it assumes 2026.1+, so on 2025.x run the step with the IDE open and its MCP server enabled. Context7 uses the remote endpoint `https://mcp.context7.com/mcp` with the header `Authorization: Bearer YOUR_API_KEY`. Junie and Claude Desktop use the stdio package `@upstash/context7-mcp` instead, with the key in `CONTEXT7_API_KEY`.

Jmix Docs uses `https://docs-mcp.jmix.io/mcp` without an API key; Junie and Claude Desktop connect through the `mcp-remote` stdio bridge.

Below are the entries the installer writes for each agent. Merge them into the existing project or user file.

### Claude Code

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

- Jmix Docs MCP:
    ```bash
    claude mcp add --scope user --transport http jmix-docs https://docs-mcp.jmix.io/mcp
    ```

### Codex

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

- Jmix Docs MCP, `.codex/config.toml` or `~/.codex/config.toml`:
    ```toml
    [mcp_servers.jmix-docs]
    url = "https://docs-mcp.jmix.io/mcp"
    ```

### OpenCode

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

- Jmix Docs MCP, `opencode.json` or `~/.config/opencode/opencode.json`:
    ```json
    {
      "mcp": {
        "jmix-docs": {
          "type": "remote",
          "url": "https://docs-mcp.jmix.io/mcp",
          "enabled": true
        }
      }
    }
    ```

### Junie

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

- Jmix Docs MCP, `.junie/mcp/mcp.json` or `~/.junie/mcp/mcp.json`:
    ```json
    {
      "mcpServers": {
        "jmix-docs": {
          "command": "npx",
          "args": ["-y", "mcp-remote", "https://docs-mcp.jmix.io/mcp"]
        }
      }
    }
    ```

### Cline

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
    },
    "jmix-docs": {
      "type": "streamableHttp",
      "url": "https://docs-mcp.jmix.io/mcp"
    }
  }
}
```

### Claude Desktop

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
    },
    "jmix-docs": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://docs-mcp.jmix.io/mcp"]
    }
  }
}
```

After a change, quit Claude Desktop completely (not just its window) and start it again.

## 4. Playwright Tests

[Playwright](https://playwright.dev) lets the agent verify a running application in the browser, from navigation to complex UI behavior. The toolkit registers the [Playwright MCP server](https://github.com/microsoft/playwright-mcp) (`@playwright/mcp`), which the agent starts through `npx` (Node.js 20+).

Add the server to the files listed in [MCP Servers](#3-mcp-servers):

- Claude Code: `claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest`.

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
