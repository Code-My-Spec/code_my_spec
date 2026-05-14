# CodeMySpec Generators

Reference for the `code_generation` agent task. Covers the standard
`mix phx.gen.auth`, `mix cms_gen.*`, and integration-provider generators
that scaffold auth, multi-tenancy, OAuth integrations, and the feedback
widget for a new project.

## When to read what

| You need...                              | Read              |
|------------------------------------------|-------------------|
| Generator order and post-generator steps | `workflow.md`     |
| Integration provider command pattern     | `workflow.md`     |
| Format for the reproducible bash script  | `script-format.md` |

## How this fits in the requirement graph

The `code_generation` requirement (in `project_graph`) is satisfied when
`.code_my_spec/tasks/code_generation.sh` exists and is non-empty. The agent
task `CodeMySpec.AgentTasks.CodeGeneration` renders a prompt with the
current state (which generators have already run, which ADRs exist, which
integration providers are declared) and tells the agent to read the
playbook and produce the script.
