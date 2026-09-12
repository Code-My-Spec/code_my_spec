defmodule CodeMySpecSpex.Story1054.Criterion3297Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3297 — An agent mid-response shows work in flight.

  Rule: busy is a state the view can report, not one it has to infer.

  The plain case. An agent has asked its model for a response and is receiving
  it; the view says so. No silence, no threshold, no judgement — just the fact,
  reported because the server has it.

  3279 is the same fact under pressure: a silence long enough to look like a
  fault, where a verdict computed from elapsed time overrides it. This one is
  the fact on its own, and it is worth its own criterion because it is the piece
  3279 depends on — a view that cannot say "in flight" at all cannot be asked
  not to contradict it. Written this way round, the failure reads as "the view
  has no notion of in-flight work" rather than as "the stall detection is wrong",
  which is a different fix.

  Asserted positively rather than as the absence of a stall, for the same
  reason: this criterion is about the view having the fact, not about what it
  does with it.

  ## Not the words "in flight"

  The first draft asserted that phrase appeared anywhere in the view, and it
  passed with the fact deliberately blinded out — because every agent carries an
  `in flight:` label whether or not a turn is open, and a label is not an
  answer. The assertion is on that line's *content*.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent receiving a response reads as busy" do
    scenario "an agent has a turn open with its model" do
      given_ "an agent that has just started a turn", context do
        reply = join_working_copy(context, "/tmp/spex-3297", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3297"
          )

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file"
          )

        # Started and not finished — no elapsed time involved, which is the
        # difference between this criterion and 3279.
        :ok = CodeMySpecSpex.Fixtures.start_turn(scope, agent.id)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "it is shown as having work in flight", context do
        line = in_flight_line(context.view)

        assert line,
               """
               The view has no notion of work in flight at all.

               view:
               #{context.view}
               """

        refute line =~ ~r/nothing|none|no turn/i,
               """
               The agent is reported as having nothing in flight while its turn
               is still open.

               The server was told the turn started and told nothing since, so
               the fact is in hand — this is reporting it, not inferring
               anything. Without it the main agent cannot tell a busy agent from
               a quiet one, and every criterion that depends on that distinction
               (3279 most of all) has nothing to stand on.

               in flight: #{line}
               """

        {:ok, context}
      end
    end
  end

  # The `in flight` line on its own.
  #
  # Asserting on the whole view for the words "in flight" matches the *label*,
  # which every agent carries whether or not a turn is open — so it passed with
  # the fact blinded out. What this criterion is about is the line's answer.
  defp in_flight_line(view), do: first_line(Regex.run(~r/in flight:[^\n]*/i, view))

  defp first_line(nil), do: nil
  defp first_line([line | _]), do: String.trim(line)
end
