# Arm the wake fixture and report what it looks like. Run it either side of a
# transition you drive yourself.
#
# Usage: mix cms.seed priv/repo/qa_wake_probe.exs
#
# ## The problem this exists for
#
# The fixture's agents are rows with no processes, and `record_running_on_copy/3`
# reaps exactly that within ~60s of each harness report (`0c912986`, and
# correctly — a row claiming life with nothing behind it is what that issue was
# filed about). `project_wakeable?/2` requires `:running`, so a reaped fixture is
# invisible to `wake_project_roles/2` and no wake is sent.
#
# That failure is silent and it mimics the defect under test. Story 1004's
# attempt `38331c19` drove a real requirement transition, verified the graph
# recomputed, observed no message, and filed the story's central criterion as
# failing. The evidence was sound; the premise underneath it had expired. Issue
# `06eda4cf`, dismissed; `726766b0` tracks the fixture problem itself.
#
# ## Why this does not drive the transition too
#
# It cannot, and finding that out is worth recording. `mix cms.seed` runs
# database-only with no supervision tree, so `GraphWatcher.ensure_watching/1`
# exits with `no process`. Nor would writing the row help: a separate OS process
# does not share PubSub with the running app, so the live watcher never hears
# about it.
#
# So the transition has to be driven **through the running app** — an MCP call,
# a dev route, the UI — and this script is the before/after reading around it.
#
# ## Reading the output
#
# `was` is the status found on disk, before this script restores it. `was=stopped`
# on the *first* run is the reaper having already been through, which is expected
# and is why the restore exists. `was=stopped` on the run *after* your transition
# means the reaper got there during the test, and any zero message count that run
# is the reaper rather than the wake — re-run, and keep the window short.
#
# A message count is meaningful even with nothing listening: `StopDecision.send_to/3`
# records BEFORE it dispatches, deliberately — "delivery can fail, and what the
# orchestrator decided is true whether or not anyone was there to hear it". So a
# decided wake leaves a row. That is what makes a row-only fixture legitimate for
# this question, where it would not be for a question about delivery.

import Ecto.Query

alias CodeMySpec.Agents.Agent
alias CodeMySpec.Repo

project_id = "d7f466a1-591e-4f36-8319-42633f59411e"

agents = Repo.all(from a in Agent, where: a.project_id == type(^project_id, :binary_id))

if agents == [] do
  IO.puts("\nNo agents on the fixture project. Run qa_wake_seed.exs first.\n")
  exit({:shutdown, 1})
end

messages_for = fn agent_id ->
  Repo.one(
    from m in "conversation_messages",
      join: c in "conversations",
      on: c.id == m.conversation_id,
      where: c.agent_id == type(^agent_id, :binary_id),
      select: count(m.id)
  )
end

IO.puts("")

for a <- Enum.sort_by(agents, & &1.role) do
  IO.puts(
    "  #{String.pad_trailing(to_string(a.role), 8)} #{a.id}  was=#{a.status}  messages=#{messages_for.(a.id)}"
  )
end

# Restored after the reading, so the reading says what was actually on disk.
{restored, _} =
  Repo.update_all(
    from(a in Agent,
      where:
        a.project_id == type(^project_id, :binary_id) and a.continuous == true and
          a.status != :running
    ),
    set: [status: :running]
  )

reaped = Enum.count(agents, &(&1.status != :running))

IO.puts("""

restored #{restored} row(s) to :running — #{DateTime.utc_now() |> DateTime.to_iso8601()}

#{if reaped == 0 do
  "Nothing had been reaped since the last run."
else
  "#{reaped} row(s) had been reaped. If that is the run AFTER your transition, " <>
    "a zero message delta is the reaper and not the wake — re-run and keep the window short (726766b0)."
end}

Next: drive the transition through the RUNNING app, then run this again and
compare the message counts. Nothing here can drive it — no supervision tree,
no shared PubSub.
""")
