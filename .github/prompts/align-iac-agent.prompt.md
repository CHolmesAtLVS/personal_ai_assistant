---
description: "Review and align an IaC agent file against this project's Terraform conventions. Reviews planning file paths, naming patterns, output directories, and skill references then applies fixes."
argument-hint: "Agent file to review, e.g. .github/agents/iac-specialist.md"
agent: "agent"
tools: [search, read, edit]
---

Review the agent file `$ARGUMENTS` (default: `.github/agents/iac-specialist.md`) against this project's Terraform conventions and apply all necessary fixes.

## Project conventions to enforce

| Convention | Expected value |
|---|---|
| Terraform output directory | `terraform/` |
| Planning files directory | `./plan/` |
| Plan file naming pattern | `infrastructure-azure*.md` and `feature-*.md` |
| Plan file reference format | `plan/infrastructure-azure-{topic}-{n}.md` |
| Skills for best practices | `azure-avm-terraform`, `terraform-engineer` |
| Instruction files | None committed — use skills instead |

## Review steps

1. **Read** the agent file in full.
2. **Read** `./plan/` directory listing to confirm actual file names and patterns.
3. **Read** `.github/skills/` directory listing to confirm available skills.
4. **Read** `terraform/` directory listing to confirm the actual Terraform root.

## Check for misalignments

Flag and fix each of the following if present:

- [ ] `infra/` as default output path → replace with `terraform/`
- [ ] `.terraform-planning-files/` or any other planning directory → replace with `./plan/`
- [ ] `INFRA.{goal}.md` file naming → replace with `infrastructure-azure*.md` / `feature-*.md`
- [ ] References to `terraform-azure.instructions.md` or `terraform.instructions.md` → replace with available project skills
- [ ] Any tool name references that do not match VS Code built-in tool sets → flag for user review
- [ ] Hardcoded subscription IDs, tenant IDs, or other deployment identifiers → remove

## Output

After applying fixes, summarize:
1. What was changed and why
2. Any items that could not be auto-fixed and require user input
3. Whether any project skills should be added to the agent's `tools:` frontmatter
