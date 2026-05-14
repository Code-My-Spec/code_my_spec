# Code Generation Script Format

The `code_generation` task produces a reproducible bash script at
`.code_my_spec/tasks/code_generation.sh`. This script captures every
generator command that was run so the scaffold can be reproduced on a
fresh Phoenix project.

The evaluator's done signal is the existence of this file. Without it,
the requirement stays unsatisfied.

## Format

```bash
#!/bin/bash
# Code generation script — produced by CodeMySpec code_generation task
# Re-run on a fresh Phoenix project to reproduce this scaffold.

set -e

# Authentication (LiveView)
mix phx.gen.auth Users User users --live

# Multi-tenant accounts
mix cms_gen.accounts

# OAuth integrations
mix cms_gen.integrations

# OAuth providers (one per .code_my_spec/integrations/*.md)
mix cms_gen.integration_provider GitHub github
mix cms_gen.integration_provider Google google

# Feedback widget
mix cms_gen.feedback_widget
```

## Rules

- **`set -e` at the top.** First failure aborts the script — no partial scaffolds.
- **One comment per generator** describing what it produces.
- **Generators in dependency order.** Each generator's output is a prerequisite
  for the next. See [workflow.md](workflow.md) for the order.
- **Integration providers go after `cms_gen.integrations`** and before
  `cms_gen.feedback_widget`.

## Empty-project case

If no generators are needed for this project (no ADRs reference generated
code), write an empty script with just the shebang and a one-line comment:

```bash
#!/bin/bash
# No generators needed for this project.
```

The evaluator still checks for the file's existence and that it's non-empty
— the comment line counts.

## Rewrite, don't append

Each run of the `code_generation` task rewrites the script from the
currently-detected project state. The script should match what's
actually in the project today, not accumulate history.

If a prior version exists, the new script replaces it. Confirm with the
user before overwriting if the new script differs substantively from the
old one — the user may have hand-edited.
