#!/usr/bin/env python3
"""Fail when a content/skills/*/SKILL.md frontmatter would be rejected by a strict agent.

Codex before 0.142 and Junie parse the frontmatter as strict YAML and skip the
whole skill on an error -- an unquoted ': ' inside a description is enough.
Requires PyYAML. Usage: tests/check_skill_frontmatter.py [REPO_DIR]
"""
import glob
import os
import sys

import yaml

repo = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors = []
paths = sorted(glob.glob(os.path.join(repo, "content", "skills", "*", "SKILL.md")))
for path in paths:
    skill = os.path.basename(os.path.dirname(path))
    with open(path, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        errors.append(f"{skill}: starts with a UTF-8 BOM")
        continue
    text = raw.decode("utf-8").replace("\r\n", "\n")
    head, sep, rest = text.partition("\n---\n")
    if not head.startswith("---\n") or not sep:
        errors.append(f"{skill}: no '---' frontmatter block at the top")
        continue
    try:
        meta = yaml.safe_load(head[4:])
    except yaml.YAMLError as e:
        errors.append(f"{skill}: invalid YAML ({str(e).splitlines()[0]}); quote values containing ': '")
        continue
    if not isinstance(meta, dict):
        errors.append(f"{skill}: frontmatter is not a mapping")
        continue
    if meta.get("name") != skill:
        errors.append(f"{skill}: name '{meta.get('name')}' does not match the folder")
    if len(skill) > 64:
        errors.append(f"{skill}: name longer than 64 characters")
    description = meta.get("description")
    if not isinstance(description, str) or not description.strip():
        errors.append(f"{skill}: description is missing")
    elif len(description) > 1024:
        errors.append(f"{skill}: description longer than 1024 characters")

if not paths:
    errors.append("no content/skills/*/SKILL.md found")
for e in errors:
    print(f"FAIL: {e}")
if errors:
    sys.exit(1)
print(f"ok: {len(paths)} skill frontmatters are strict YAML")
