# Jmix Agent Toolkit

Agent skills, guidelines and tools that teach AI coding agents the Jmix-specific patterns, mandatory rules and best practices for developing applications with the [Jmix framework](https://www.jmix.io/).

The toolkit adds three things to your project:

- **Skills**: instructions and rules for Jmix features such as entities, views and data access. Browse them in [`skills/`](skills).
- **Guidelines**: a short block in `AGENTS.md` that points the agent at the `jmix` skill, the entry point to the others.
- **MCP servers**: connections to IntelliJ IDEA, documentation and a browser, see [MCP Servers](#mcp-servers).

Supported agents: Claude Code and every agent that reads `.agents/skills` and `AGENTS.md`, such as Codex, OpenCode, Junie, Cline, Cursor, GitHub Copilot and Gemini CLI.

Each Jmix major version has its own branch, named `v<major>`. This is the `v2` branch. For a project on another Jmix major, switch to that branch and use its commands.

## Installation

| Method                                      | Installs                        | Needs                 |
|:--------------------------------------------|:--------------------------------|:----------------------|
| [Installer script](#quick-cli-installation) | Skills, guidelines, MCP servers | bash or PowerShell 5+ |
| [npx skills](#npx-skills)                 | Skills only                          | Node.js               |
| [Jmix Studio](#jmix-studio)                 | Skills, guidelines, MCP servers | Jmix Studio 3.0+      |

To set everything up by hand, follow [Manual Installation](docs/manual-installation.md).

<!-- docs.jmix.io links to #quick-cli-installation: keep this heading -->

### Quick CLI Installation

One command starts a wizard that asks about each step: skills, guidelines, MCP servers. Run it from the project root.

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.sh | bash
```

**Windows (PowerShell 5+):**

```powershell
Invoke-RestMethod https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.ps1 | Invoke-Expression
```

<details>
<summary>If Windows blocks the script</summary>

If the execution policy blocks the script, bypass it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod 'https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.ps1' | Invoke-Expression"
```

If `powershell.exe` itself is blocked by a corporate policy (`CreateProcess error=5, Access is denied`), use PowerShell 7 (`pwsh`):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod 'https://raw.githubusercontent.com/jmix-framework/jmix-agent-toolkit/v2/install.ps1' | Invoke-Expression"
```

</details>

Each step is also a subcommand, for scripts and CI: see the [installer reference](docs/installer.md).

### npx skills

The [npx skills](https://github.com/vercel-labs/skills) installs the skills for the agents you pick. Run it from the project root:

```bash
npx skills add https://github.com/jmix-framework/jmix-agent-toolkit/tree/v2
```

Keep the branch in the URL: it selects the skills for your Jmix major. When the CLI asks which skills to install, pick all of them, because the `jmix` skill routes each task to the others. With `-g` the skills go to your home directory instead of the project.

The `skills` CLI installs the skills only. For the guidelines and the MCP servers, run the [installer script](#quick-cli-installation) and answer `n` at its skills step. Both tools put the Jmix skills into `.agents/skills`, so manage the skills with one tool per project or home directory.

### Jmix Studio

In Jmix Studio 3.0+, run the **AI Agents Toolkit** action from the **Settings** menu of the **Jmix** tool window and follow the wizard.

## MCP Servers

Jmix Studio and the installer script register these servers for Claude Code, Codex, OpenCode, Junie and Cline:

| Server       | Gives the agent                                              | Needs                             |
|:-------------|:-------------------------------------------------------------|:----------------------------------|
| `jetbrains`  | The code analysis and inspections of a running IntelliJ IDEA | The MCP server enabled in the IDE |
| `context7`   | Docs and code examples from official sources                 | A Context7 API key                |
| `jmix-docs`  | Jmix documentation, Java API and UI samples                  | -                                 |
| `playwright` | A browser to check the running application                   | Node.js 20+                       |

`jetbrains` is highly recommended. To enable it, go to **Settings → Tools → MCP Server** in IntelliJ IDEA, select **Enable MCP Server** and keep your project open in the IDE. `context7` and `jmix-docs` are optional.

Servers registered in the project files need a confirmation: Claude Code asks to approve the servers in `.mcp.json`, and Codex reads `.codex/config.toml` only in trusted projects.

With Playwright, give the agent instructions like:

> Run the app and use Playwright MCP to log in and test all created views

The config files and the entries for each agent are in [Manual Installation](docs/manual-installation.md#3-mcp-servers).

## Next Steps

Start the agent in the project and describe a task in Jmix terms: entities, attributes, views, roles. The [AI Agent Setup](https://docs.jmix.io/jmix/agent-setup.html) guide shows how to check that the agent sees the skills and the MCP servers, and how to make a first request.

To update the toolkit, run the Studio action or the installer script again: it replaces the Jmix skills and its own block in `AGENTS.md`, and keeps your text outside the block. If you installed the skills with the `skills` CLI, run `npx skills update`.