# Agent context

Which story an agent is working on, carried on the scope rather than asked for
on every call.

Status: **design**. Nothing below is built.

## The problem

`story_number` is an optional parameter on the tools that take it, and agents
leave it out. `QaAttempts.submit/2` says so in its own comment:

> asking the agent to remember `story_number` on every `create_issue` call did not
> work — every accepted issue on this project reached triage with none.

So attribution was moved to submission time: `Issues.attribute_to_story/3` runs
when a QA attempt lands, over the ids the agent listed in `issue_ids`. That
works for issues the agent remembers to link, and nothing else. Measured
2026-09-22: **83 of 169** app-scoped issues on Broken Oaths carry a story, **6
of 10** on the math project. An unattributed issue can never gate the story it
is about.

The same shape recurs wherever a caller can disagree with the system about
which story it is on, and every instance of it this session cost an hour:
`list_issues` unfiltered against an `issues_resolved` gate that counts only
`:app`; `devops_status` reporting provisioned infrastructure as absent;
`get_next_requirement` answering per vantage.

Adding a default to one tool is not the fix. It was tried and it is what the
comment above is describing.

## The shape

`Scope` already carries exactly this kind of fact, with the reasoning written
down:

> Which working copy of the project this scope speaks for. Files and problems
> are projections of one checkout, so a read or write of them without this is a
> statement about the project that no checkout made.

Story is the same statement one level down. A scope that does not name a story
is a statement about the project that no story made.

    defstruct user: nil,
              ...
              active_working_copy_id: nil,
              active_story_id: nil,          # new
              cwd: nil,
              environment: nil

## Where it resolves

Two sources, and **the task wins**:

1. **The agent's open task** — `tasks[].story_id`, on the task it is actively
   working or blocked on. Per-agent, and the more specific answer.
2. **The working copy** — `working_copies.active_story_id`, written by
   `set_active_story` and shared by every agent on that checkout. The fallback.

The task wins because an agent working a task is unambiguously on that task's
story, whatever the copy is nominally set to. The copy's value is what an agent
holding no task should read.

`with_harness/2` in `deploy_key_or_oauth.ex` already fetches the working copy
when building the scope for every MCP call, so the fallback costs nothing. The
task-level answer needs the calling agent, which `frame.assigns[:agent_id]`
already carries and several tools already read.

Epic is **not** carried. It is derivable from the story (`stories.epic_id`), and
nothing has yet needed it at call time.

## Implicit, but never silent

An agent that gets a story it did not ask for has to be told, or the next thing
it files lands somewhere it did not intend and it has no way to know.

So a tool that resolved `story_number` from context says so in its own response:

    Issue 4f9c2a11 filed against story 1053 ("Clearing the calculator starts a
    fresh calculation"), taken from the task you are working. Pass `story_number`
    explicitly if it belongs to a different story, or `story_number: null` for an
    issue that is not story-specific.

**Text, not JSON, and this is not a style preference.** `structured_content` on
an MCP response makes Claude latch onto the JSON and stop reading the text —
found the hard way here: an agent saw `{"status": "init_required"}` and never
read the init checklist, and `start_task` returned a `task_id` in structured
content while the work prompt went unread. The announcement's entire job is to
be read and acted on. Returning the story as JSON is the one shape guaranteed
to make the agent skip the sentence telling it how to override.

So: `Response.text/1`, with the story number and title in the prose, like every
other mapper here.

A default that does not announce itself is the `devops_status` failure in
another costume: the caller reads a confident answer, has no reason to doubt it,
and acts on something that is not true. Three of this session's longest detours
were exactly that.

## What changes at the call sites

Tools stop treating `story_number` as something the caller must remember:

- absent from params and resolvable from context → use it, and say so
- present in params → use that, say nothing, never override
- absent and unresolvable → unchanged behaviour, no story

`create_issue`, `submit_qa_result`, `show_story_requirements`,
`list_qa_attempts` and their neighbours all stop being able to disagree about
which story they are on.

## `null` means deliberately none

An explicit `story_number: null` is "this is not about a story", and is honoured —
distinct from omitting it, which means "you work it out". A project-level issue
raised by an agent that happens to be mid-story is a real case, and without the
distinction the implicit default would capture it.

So three states, not two:

| caller passes | means |
|---|---|
| a story number | that story, no announcement, never overridden |
| nothing | resolve from context, and say so |
| `null` | deliberately not story-specific, resolve nothing |

## Open question, deliberately left

`set_active_story` writes the copy-level value for every agent on that checkout.
With the task grain winning, it may now only serve agents holding no task.
Worth revisiting once the task grain is in and it is clear what still reads it —
not worth deciding in advance.
