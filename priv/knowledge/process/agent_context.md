# Agent context

Which story an agent is working on, carried on the scope rather than asked for
on every call.

Status: **design**. Nothing below is built.

## The problem

`story_id` is an optional parameter on the tools that take it, and agents leave
it out. `QaAttempts.submit/2` says so in its own comment:

> asking the agent to remember `story_id` on every `create_issue` call did not
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

So a tool that resolved `story_id` from context says so in its own response:

    Issue 4f9c2a11 filed against story 1053 ("Clearing the calculator starts a
    fresh calculation"), taken from the task you are working. Pass `story_id`
    explicitly if it belongs to a different story, or `story_id: null` for none.

This is the rule the rest of the system already learned the hard way. A default
that does not announce itself is the `devops_status` failure in another costume:
the caller reads a confident answer, has no reason to doubt it, and acts on
something that is not true. Three of this session's longest detours were exactly
that.

## What changes at the call sites

Tools stop treating `story_id` as something the caller must remember:

- absent from params and resolvable from context → use it, and say so
- present in params → use that, say nothing, never override
- absent and unresolvable → unchanged behaviour, no story

`create_issue`, `submit_qa_result`, `show_story_requirements`,
`list_qa_attempts` and their neighbours all stop being able to disagree about
which story they are on.

## Open questions

- Should `story_id: null` be expressible as "deliberately no story", distinct
  from "did not say"? A project-level issue filed by an agent mid-story is a
  real case, and the implicit default would currently capture it.
- `set_active_story` writes the copy-level value for every agent on that
  checkout. With the task grain winning, is the copy-level value still worth
  keeping, or does it only serve agents holding no task?
