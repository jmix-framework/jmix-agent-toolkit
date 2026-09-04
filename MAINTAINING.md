# Maintaining the Jmix AI Agent Toolkit

## Structure

- **One branch per Jmix major**: `v2` (Jmix 2), `v3` (Jmix 3), … The repository
  **default branch** is the current stable major, so `HEAD` points at it.
- Each branch is **self-contained**:
  - `content/` — `guidelines-block.md` (the marker-delimited block merged into the
    project's own guidelines file) + `skills/<skill>/SKILL.md`. The `jmix` skill is
    the umbrella the block points at; the rest are per-artifact skills.
  - `install.sh` / `install.ps1` — installers. Each contains branch name inside
    `CONTENT_REF` (sh) / `$ContentRef` (ps1) and installs from `content/`.
  - `.studio/` — `studio-meta-data.json` (Studio wizard steps), `skills-manifest.json`
    (generated: `{store, skills, sha256}`), `gen_skills_manifest.py` (the generator).
  - `tests/`, `.github/workflows/` — installer tests + CI (manifest regen, installer tests).

There is no in-repo version resolution: the branch **is** the version, and each
branch holds exactly one `content/` folder.

## How install works

- **CLI**: `curl -fsSL .../jmix-agent-toolkit/<branch>/install.sh | bash`.
  The script downloads its own branch tarball (`CONTENT_REF`), installs `content/skills`
  into the canonical store `~/.agents/.jmix/skills/<branch>/`, symlinks each skill folder
  (`jmix` and `jmix-*`) into every selected agent's skills dir, and merges
  `content/guidelines-block.md` into the project's guidelines file. `HEAD` resolves to
  the default branch (newest stable major).
- **Jmix Studio**: the **AI Agents Toolkit** wizard computes the branch from the project's
  Jmix major (`v<major>`), fetches `.../v<major>/.studio/studio-meta-data.json` (falling back
  to the default branch if that branch does not exist yet), then runs the per-branch
  `install.sh` / `install.ps1` and passes that branch as `--content-ref` / `-ContentRef`.
  A Intellij IDEA Registry override can pin all three to a feature branch for pre-merge testing.

## Cutting a new version branch (e.g. Jmix 4 → `v4`)

1. Branch from the latest: `git switch v3 && git switch -c v4`.
2. Update `content/` for the new major (`AGENTS.md` stack + the `skills/`).
3. Set the branch identity in both installers:
   - `install.sh`: `CONTENT_REF="v4"`
   - `install.ps1`: `$ContentRef = 'v4'`
4. Regenerate the manifest: `python3 .studio/gen_skills_manifest.py`.
5. Run the installer tests:
   - `bash tests/test_install_sh.sh`
   - `pwsh tests/test_install_ps1.ps1`
6. Push the branch. When the new major becomes the current stable one, make it the
   repository default branch:
   `gh repo edit jmix-framework/jmix-agent-toolkit --default-branch v4`.