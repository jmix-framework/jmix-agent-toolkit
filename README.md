# Jmix AI Agent Toolkit

This repository provides a collection of guidelines and "agent skills" designed to help AI coding agents develop applications using the [Jmix framework](https://www.jmix.io/) effectively.

The AI agent will use these resources to understand Jmix-specific patterns, mandatory rules, and best practices.

## Repository Structure

Each Jmix major version lives on its own branch: `v2` for Jmix 2, `v3` for Jmix 3, and so on. The repository default branch is the current stable major. Each branch holds a single `content/` folder:

- `content/` contains the guidelines for that branch's Jmix version.
  - `AGENTS.md`: General coding guidelines, architecture overview, and development workflow for Jmix projects.
  - `skills/`: A collection of folders, each containing:
      - `SKILL.md`: Detailed instructions and rules for the agent regarding a specific Jmix feature.
      - Optional subdirectories with examples or other materials.

## Studio Installation

The simplest way to install agent toolkit to your project is to use Jmix Studio 3.0+. 

Execute the **AI Agents Toolkit** action in the **Settings** menu of the **Jmix** tool window and follow the steps of the GUI interactive wizard.

## Quick CLI Installation

A single command launches an interactive wizard that walks through every setup step: 
installing skills, adding guidelines, registering the recommended MCP servers, and setting up Playwright testing.

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
install.sh mcp-jetbrains --agents CSV
install.sh mcp-context7  --agents CSV   [--context7-key KEY]
install.sh playwright    --agents CSV   # requires npx (Node.js) on PATH
```

PowerShell mirrors the same shape: `install.ps1 skills -Agents claude,codex`, `install.ps1 mcp-context7 -Agents claude -Context7Key KEY`, `install.ps1 playwright -Agents claude,codex`, etc.

**CSV** = comma-separated agent list (e.g. `claude,codex`) or a single value (e.g. `claude`).

### Flags

| Flag (bash)               | Flag (PowerShell)      | Default | Meaning                                                                                                                                                                                                        |
|:--------------------------|:-----------------------|:--------|:---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--source DIR`            | `-Source DIR`          | -       | Install from a local checkout of this repository instead of downloading. Skips the network. Mainly for CI and offline use.                                                                                     |
| `--agents CSV`            | `-Agents CSV`          | -       | Comma-separated agents. Required by every subcommand.                                                                                                                                                          |
| `--scope global\|local`   | `-Scope global\|local` | global  | `skills` only. `global` installs the store under `~/.agents/.jmix/skills/v<major>`; `local` installs the store at `<project>/.skills`. Agent dirs are symlinked to the store.                                  |
| `--context7-key K`        | `-Context7Key K`       | prompt  | Context7 API key. Prompted interactively when omitted.                                                                                                                                                         |
| `--backup-existing-files` | `-BackupExistingFiles` | off     | Rename overwritten files/dirs to a deduped `<name>.bak` instead of deleting them. Off by default. Guidelines files (`CLAUDE.md` / `AGENTS.md` / `guidelines.md`) are always backed up regardless of this flag. |
| `--verbose`, `--debug`    | `-Verbose`             | off     | Print extra diagnostic output (OS, PATH, resolved paths, tool versions) for troubleshooting.                                                                                                                   |

**Skills storages:**
- **Global:** store at `~/.agents/.jmix/skills/v<major>/` (e.g. `v3`); each `jmix-*` folder symlinked into `~/.claude/skills` (Claude CLI), `~/.agents/skills` (Codex, OpenCode), `~/.junie/skills` (Junie).
- **Local:** store at `<project>/.skills/`; each `jmix-*` folder symlinked into `<project>/.agents/skills`, `<project>/.claude/skills`, `<project>/.junie/skills`.

> The automatic installer covers skills (installed globally or into the project), project guidelines, MCP server registration, and Playwright testing skills. The Playwright step runs `@playwright/cli` via `npx`, so `npx` (Node.js) must be available on PATH.

## Manual Installation

If you prefer not to run the script, follow these steps. Check out the branch for your Jmix major and take the files from its `content/` folder.

### 1. Project Guidelines

Copy the `AGENTS.md` file from this repository to the root of your Jmix application project. Depending on the agent you are using, you may need to rename it or place it in a specific folder:

- [Claude CLI](https://code.claude.com/docs): Copy to the project root and rename to `CLAUDE.md`.
- [Codex](https://developers.openai.com/codex/cli): Copy to the project root and keep as `AGENTS.md`.
- [OpenCode](https://opencode.ai/docs): Copy to the project root and keep as `AGENTS.md`.
- [Junie](https://www.jetbrains.com/junie): Copy to the `.junie` project subdirectory and rename to `guidelines.md`.

### 2. Agent Skills

The `skills/` directory contains specialized knowledge for developing various Jmix features (entities, UI views, data access, etc.). These should be made available to the agent globally or per-project.

Each skill must sit **directly** inside the agent's skills folder (e.g. `~/.claude/skills/jmix-create-entity/`) — agents do not scan nested subfolders, so the skills must be linked **individually**. Do not symlink the whole `skills/` directory as a single entry, and note that the folder normally holds other (non-Jmix) skills that must be left in place.

Copy or symlink each folder from `skills/` into the folder recognized by your agent in your project or user home directory:

| Agent      | Project Skills Folder Path | Global Skills Folder Path |
|:-----------|:---------------------------|:--------------------------|
| Claude CLI | `.claude/skills/`          | `~/.claude/skills/`       |
| Codex      | `.agents/skills/`          | `~/.agents/skills/`       |
| OpenCode   | `.agents/skills/`          | `~/.agents/skills/`       |
| Junie      | `.junie/skills`            | `~/.junie/skills/`        |

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
| Junie      | `.junie/guidelines.md` | `~/.junie/`           |

### 3. MCP Servers

The following two MCP servers help AI agents to build Jmix apps:

- JetBrains (**highly recommended**): lets an external agent talk to a running IntelliJ IDEA to leverage code analysis and inspections.

- Context7 (optional): gives the agent docs and code examples from official sources.

To run the JetBrains MCP server in IntelliJ IDEA, go to **Settings → Tools → MCP Server** and select **Enable MCP Server ✓**. When working with a project, keep it open in the IDE.

Below are practical setup snippets per agent.

#### Claude CLI

- JetBrains MCP:
    ```bash
    claude mcp add --transport sse jetbrains --scope user http://localhost:64342/sse
    ```

- Context7 MCP:
    ```bash
    claude mcp add context7 --scope user -- npx -y @upstash/context7-mcp --api-key YOUR_API_KEY
    ```

#### Codex

- JetBrains MCP:

  If you have IntelliJ IDEA 2026.1 or above, execute the following command to use Streamable HTTP connection:

    ```bash
    codex mcp add jetbrains --url http://localhost:64342/stream
    ```

  For an older IntelliJ IDEA version, follow the steps below to use STDIO connection.

  Open **Settings → Tools → MCP Server** and click **Copy Stdio Config** in **Manual Client Configuration** section. Paste the JSON into a text editor. You will see something like this:

    ```json
    {
      "type": "stdio",
      "env": {
        "IJ_MCP_SERVER_PORT": "64342"
      },
      "command": "<your path to java>",
      "args": [
        "-classpath",
        "<your very long classpath>",
        "com.intellij.mcpserver.stdio.McpStdioRunnerKt"
      ]
    }
    ```

  Open the terminal and run the following command using the values from the JSON:

    ```bash
    codex mcp add jetbrains --env IJ_MCP_SERVER_PORT=64342 -- "<your path to java>" -classpath "<your very long classpath>" "com.intellij.mcpserver.stdio.McpStdioRunnerKt"
    ```

- Context7 MCP:
    ```bash
    codex mcp add context7 -- npx -y @upstash/context7-mcp --api-key YOUR_API_KEY
    ```

#### OpenCode

Add to your `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "jetbrains": {
      "type": "remote",
      "url": "http://localhost:64342/sse",
      "enabled": true
    },
    "context7": {
      "type": "local",
      "command": ["npx", "-y", "@upstash/context7-mcp", "--api-key", "YOUR_API_KEY"],
      "enabled": true
    }
  }
}
```

#### Junie

- JetBrains MCP: not required. Junie runs inside the IntelliJ and already has native access to the IDE features.

- Context7 MCP: 
  
    Open **Settings → Tools → Junie → MCP Settings** and click **Add**. Paste the following JSON into the text field:

    ```json
    {
      "mcpServers": {
        "context7": {
          "command": "npx",
          "args": ["-y", "@upstash/context7-mcp", "--api-key", "YOUR_API_KEY"]
        }
      }
    }  
    ```
  
### 4. Playwright Tests

[Playwright](https://playwright.dev) integration provides AI agents with the ability to perform UI verification on a running application. This allows the agent to test navigation and complex UI behaviors directly in the browser.

To enable Playwright support:

- Install Playwright CLI globally:
    ```bash
    npm i -g @playwright/cli@latest
    ```

- Install Playwright skills:
    ```bash
    playwright-cli install --skills
    ```
    The command above creates Playwright skills in the `.claude/skills` directory of the current working directory. Run it from your home directory to install them globally into `~/.claude/skills`. If you are using a different agent, copy or symlink them to the directory supported by your agent (see [Agent Skills](#2-agent-skills) section).

Once set up, you can give the agent instructions like:

> Run the app and use playwright skill to login and test all created views
