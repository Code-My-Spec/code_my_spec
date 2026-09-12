# The product process

How a story gets from "somebody said it" to "an agent is working on it".

This document is the map. The per-task playbooks — `story_interview/`,
`three_amigos/`, `persona_research/` — are the territory, and each one
assumes you have read this. If you are about to run one task, read its
playbook. If you are wondering why the task is not being offered to you,
read this.

## The shape

A story is a row, not a file. Everything below happens to that row, and
the only way you see any of it is by asking the tools.

```
written down  →  shaped  →  specified  →  released for work  →  worked on
story_interview   three_amigos             ready_for_dev +        the graph
                  (+ persona_research)     assigned to a          offers tasks
                                           working copy
```

The first three are agent work with playbooks. The fourth is **not agent
work** and has no playbook, which is exactly why it is the step that gets
missed. See "Released for work" below.

## Written down

`story_interview` produces the story: a title, a description, and an
`acceptance_criteria` string. A story at this stage is a claim about what
somebody wants. It is not yet specified and nothing can be built from it.

Quality rules for the story text itself are in
`story_interview/workflow.md`. They are load-bearing — a vague story
survives all the way to an agent writing the wrong specs.

## Shaped

`three_amigos` runs an Example Mapping session and leaves behind personas,
rules, scenarios and questions on the story. When the conditions hold, the
story is **sealed**, which satisfies `three_amigos_complete`.

The protocol, the conditions and the anti-patterns are in
`three_amigos/workflow.md`. Two things about it that belong here rather
than there:

- **Sealing is one-way.** There is no unseal. A question raised after
  sealing is the next conversation, not a reason to reopen this one.
- **Sealing is not permission to start building.** It satisfies one
  requirement. The story still has to be released for work, and sealing
  does not do that.

## Specified

`bdd_specs_exist` wants spec files on disk under `test/spex/`. The
conventions for writing them are in `bdd/spex/` and are not repeated here —
start at `bdd/spex/index.md`, and read `bdd/spex/writing_a_spex.md` before
your first one.

One detail that is process rather than craft, because getting it wrong
puts good specs in a directory nothing reads:

> **The spex directory is named from the story's NUMBER, not its ID.**

Every MCP tool takes the **id**. `get_story`, `update_story`, `add_rule`,
`start_task` — all id. The spex directory is
`test/spex/<number>_<slug>/`, and the number is a different integer.
Story id 1031 is story number 1065, and its specs live in
`test/spex/1065_.../`.

They are different because the id is the database primary key and the
number is the story's position in the project — so for a project whose
stories happen to start at 1, they coincide for a while, and an agent that
assumes they are the same is right for months. Read the number off the
story rather than assuming; `get_story` returns both.

## Released for work

**This is the step with no playbook, and the one that silently stops
everything.** Two things have to be true before the requirement graph will
offer a single task on a story:

1. **The story is marked ready for development.** A story that is sealed
   but not released is finished product work that nobody has said to build
   yet. That distinction is deliberate — shaping a story and committing to
   building it are different decisions, often made weeks apart.

   This is a filter and deliberately not a requirement node. A
   `ready_for_dev` node would show up as actionable work, an agent would
   satisfy it, and it would gate nothing.

2. **The story is not assigned to a different working copy.**
   Requirements are scoped to a working copy. The rule is narrower than
   "assign your stories", and worth getting exactly right because the
   obvious reading is wrong in both directions:

   > A working copy is offered **its own stories and every unassigned
   > one**, and never another copy's.

   So assignment **narrows and never hides**. An unassigned story is
   offered everywhere — a project with no assignments at all behaves
   exactly as it did before the column existed. What disappears is a story
   assigned to *somebody else's* checkout, and that is the case to check
   when a story you can see in the backlog is offering you no work.

Assignment runs story → epic → working copy. Assigning an epic to a
working copy writes the assignment onto that epic's **stories**, so
assigning at the epic level is the bulk operation, not a separate kind of
link.

Parked stories stay reachable through the backlog tools, which query
stories directly instead of going through the graph. That is why a story
can be plainly visible and still produce no work: you are looking at it
through a surface that does not apply either filter.

### Why this is the step that costs a morning

Neither condition failing produces an error. Both produce **`0/0`
requirements and nothing to do** — the identical report you get from a
project where every requirement is already satisfied, and from a project
where nothing has been released at all. Success and "you forgot a step"
are indistinguishable from outside.

So: if an agent tells you there is nothing to work on, do not conclude the
work is done. Check that the story is ready for development, and check
which working copy it is assigned to, **before** looking anywhere else.
The check costs one tool call; the alternative is reading the graph code
to find out why it is empty, which is a morning.

## Worked on

Once released, `get_next_requirement` starts returning tasks and the
remaining families take over:

- **Code** — `process/code.md`
- **QA** — `process/qa.md`
- **Promotion to the running copy** — `process/devops.md`

## What is written down and what is not

Twelve of the forty-odd task modules have a playbook in this knowledge
base. The rest do not, and most of those are small enough that the task
prompt carries everything.

Where a task has no playbook and is *not* self-evident, that is a gap
worth filling rather than a decision — `promote_work` was the expensive
example, and what it should have said is now in `process/devops.md`.
