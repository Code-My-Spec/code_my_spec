defmodule CodeMySpecSpex.Story1056.Criterion3304Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3304 — Everybody carries on after the application restarts.

  Rule: the record is the intent, and coming back up is acting on it.

  Sealed story 1023 already established that an agent still working comes back
  (criterion 2890) and that one somebody stopped is not resurrected (2891). What
  this adds is the second half of its own sentence: "they pick up where they
  left off rather than waiting to be started".

  That is not the same claim and it fails separately. A restore that brings the
  agent back with an empty history produces a running agent that has forgotten
  the story it was part-way through — which looks like success from every angle
  except the one that matters, and costs the work rather than the process.

  It is also the precise failure `Agents.restart_agent/2` was written to avoid
  on the single-agent path: starting afresh inserts a new row, and a
  conversation keys on the agent id, so the replacement comes back to an empty
  thread. The restore path has to make the same guarantee, and nothing yet says
  it does.

  ## Driven through the join, which is what a restart is from the server's side

  A harness that has just come up asks `agents_to_restore`, and the answer is
  the desired state rather than anything last observed. There is no other
  observable moment: the application restarting is not an event this side sees.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Agents come back working, not merely running" do
    scenario "the application restarts while an agent is part-way through a story" do
      given_ "an agent part-way through work on a checkout", context do
        reply = join_working_copy(context, "/tmp/spex-3304", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story = Fixtures.authored_story(scope, "Refunds reach the ledger")

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3304")

        {_agent, _task} =
          Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            story_id: story.id
          )

        :ok = Fixtures.agent_said(scope, agent, "half of the ledger writer is done")

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the application comes back up and the harness asks what to run",
            context do
        {:ok, Map.put(context, :to_restore, Fixtures.agents_to_restore(context.scope))}
      end

      then_ "that agent is among the ones to run again", context do
        ids = Enum.map(context.to_restore, & &1["agent_id"])

        assert context.agent.id in ids,
               """
               An agent that was working when the application restarted is not
               brought back.

               Whatever it was part-way through is abandoned, and a restart that
               costs every agent is one nobody can afford to perform.

               to restore:
               #{inspect(ids)}
               """

        {:ok, context}
      end

      then_ "and it comes back to what it was already doing", context do
        entry = Enum.find(context.to_restore, &(&1["agent_id"] == context.agent.id))

        assert entry["messages"] != [] and entry["messages"] != nil,
               """
               The agent comes back with no memory of what it was doing.

               Running and having forgotten is worse than not coming back: it
               looks like success from every angle except the one that matters,
               and the loss is the work rather than the process. An agent
               restored into an empty thread starts the story again from the
               beginning, or — worse — starts something else.

               This is the exact failure `Agents.restart_agent/2` was written to
               avoid on the single-agent path. The restore path has to make the
               same guarantee.

               entry:
               #{inspect(entry)}
               """

        {:ok, context}
      end
    end
  end
end
