# Installer Reference

`install.sh` and `install.ps1` install the skills, the guidelines and the MCP servers. Without arguments they start the wizard, see [Quick CLI Installation](../README.md#quick-cli-installation). This page covers the subcommands, the flags and the files the installer writes.

## Subcommands

Each runs one step without the wizard. **CSV** is a comma-separated list (e.g. `claude,codex`) or a single value.

```bash
install.sh skills     [--scope global|local] [--claude=false]
install.sh agents-md  [--claude=false]
install.sh mcp        --servers CSV --agents CSV [--scope local|global] [--context7-key KEY]
install.sh mcp-jetbrains | mcp-context7 | mcp-jmix-docs | playwright --agents CSV [--scope local|global]
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

## Flags

All subcommands:

| Flag (bash)               | Flag (PowerShell)      | Default | Meaning |
|:--------------------------|:-----------------------|:--------|:--------|
| `--content-ref REF`       | `-ContentRef REF`      | `v2`    | Branch/ref whose skills and guidelines block are downloaded; it also names the global skills store. Studio passes its resolved toolkit branch. |
| `--source DIR`            | `-Source DIR`          | -       | Install from a local checkout of this repository instead of downloading (CI, offline use). |
| `--backup-existing-files` | `-BackupExistingFiles` | off     | Rename overwritten files/dirs to `<name>.bak` (`.bak1`, `.bak2`, ... when taken) instead of deleting them. Not for guidelines files: they are merged, and backed up (with or without this flag) only when the toolkit rewrites content it does not own: an older toolkit's file, or your own file getting the block. |
| `--verbose`, `--debug`    | `-Verbose`             | off     | Print diagnostics (OS, PATH, resolved paths, tool versions). |

`skills` and `agents-md`:

| Flag (bash)              | Flag (PowerShell)      | Default | Meaning |
|:-------------------------|:-----------------------|:--------|:--------|
| `--claude[=true\|false]` | `-Claude`              | on      | Set up Claude Code by default. Use `--claude=false` / `-Claude:$false` to skip `.claude/skills` links and `CLAUDE.md`. `.agents/skills` and `AGENTS.md` are always installed. |
| `--scope global\|local`  | `-Scope global\|local` | global  | `skills`: install into the user home or the current project, see [Skills Store](#skills-store). |

`mcp`, `mcp-jetbrains`, `mcp-context7`, `mcp-jmix-docs` and `playwright`:

| Flag (bash)             | Flag (PowerShell)      | Default | Meaning |
|:------------------------|:-----------------------|:--------|:--------|
| `--agents CSV`          | `-Agents CSV`          | -       | `claude`, `codex`, `opencode`, `junie`, `cline`. Required. |
| `--servers CSV`         | `-Servers CSV`         | -       | `mcp`: `jetbrains`, `context7`, `jmix-docs`, `playwright`. Required. |
| `--scope local\|global` | `-Scope local\|global` | local   | Write the project files in the current directory or each agent's user config. Claude Desktop and Cline have only a user config. |
| `--context7-key K`      | `-Context7Key K`       | prompt  | `mcp`, `mcp-context7`: Context7 API key (letters, digits, `.`, `_`, `-`); `skip` leaves Context7 out. Never printed. At `local` scope it goes into the project files: keep them out of version control. |

## Environment Variables

- `JMIX_IDE_MCP_PORT` sets the port of the IntelliJ IDEA MCP server (default `64342`), e.g. `curl ... | JMIX_IDE_MCP_PORT=64343 bash -s -- mcp-jetbrains --agents claude`.
- `CLINE_MCP_SETTINGS_PATH`, `CLINE_DATA_DIR` and `CLINE_DIR` move Cline's MCP config, as they do for Cline itself.

## Installed Files

`skills` always installs the skills into `.agents/skills`, and `agents-md` always merges the guidelines into `AGENTS.md`: Codex, OpenCode, Junie, Cline, Cursor, GitHub Copilot, Gemini CLI and others read them there.

Claude Code is included by default: each skill is linked into `.claude/skills`, and a new `CLAUDE.md` contains only `@AGENTS.md`, so the shared instructions have one copy. Existing `CLAUDE.md` files keep the current merge and backup rules; a file that already imports `AGENTS.md` is left untouched. Use `--claude=false` (`-Claude:$false`) to skip Claude Code.

### Skills Store

The skills are copied into a store, and each skill folder is linked into `.agents/skills` and, unless `--claude=false`, into `.claude/skills`, next to any other skills there.

- **Global:** store at `~/.agents/.jmix/skills/<ref>/` (the `--content-ref`, e.g. `v2`), linked into `~/.agents/skills` and, unless `--claude=false`, into `~/.claude/skills`.
- **Local:** the store is `<project>/.agents/skills/` itself, so the skills are real folders there. Each skill is linked into `<project>/.claude/skills` unless `--claude=false`. With `--backup-existing-files`, replaced skill folders go to `<project>/.agents/.jmix/backups/`, where no agent reads them as skills.

### MCP Config Files

The MCP subcommands take **agents**, each with its own config: `claude`, `codex`, `opencode`, `junie`, `cline`. `claude` also sets up [Claude Desktop](manual-installation.md#claude-desktop) when it is installed. [Cline](manual-installation.md#cline) has only a user config, which it gets whatever the `--scope`.

The installer writes MCP servers straight into each agent's config file (see [MCP Servers](manual-installation.md#3-mcp-servers)), keeping its other servers and settings; only Claude Code at `global` scope goes through `claude mcp add`. A file that is already up to date is not rewritten. On macOS/Linux, merging into an existing JSON config file needs `jq` or `node`; a new file is written without them. Servers started through `npx` need Node.js 20+ when the agent starts them, not at install time.
