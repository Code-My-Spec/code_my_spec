defmodule CodeMySpecSpex.Story1054.Criterion3279Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3279 — A long silence with a live connection is not a stall.

  Rule: an agent that has not finished speaking has not stopped.

  The third quiet-with-a-cause criterion, and the one where the silence is not
  a symptom of anything — it is what working looks like. A long reasoning turn
  produces nothing observable until it lands: no message, no tool call, no
  edits. An agent eight minutes into one is indistinguishable from an agent that
  died eight minutes ago everywhere except the open connection.

  Killing it is the expensive mistake on this story. The turn is discarded
  mid-flight, the model spend is wasted, and the replacement starts the same
  work from the beginning — so the remedy makes the thing it was meant to fix
  take longer, and does it again next time.

  ## Why this is not 3297

  3297 asks the plain question: an agent mid-response shows work in flight.
  This one pairs it with a silence long enough to look like a fault and demands
  the silence *not* be read as one. A view could surface in-flight work
  correctly — satisfying 3297 — and still lead with "stalled" computed from a
  silence threshold that never consults it. That is the bug, and it needs the
  two conditions together to show up.

  The turn is opened through the harness's own `agent_turn_event` push and never
  closed, which is what an agent mid-response actually is from the server's
  side.
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

  spex "A response still arriving is not a stopped agent" do
    scenario "an agent has been silent for several minutes with a turn open" do
      given_ "an agent mid-turn that has said nothing for ten minutes", context do
        reply = join_working_copy(context, "/tmp/spex-3279", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3279"
          )

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            started_at: DateTime.add(DateTime.utc_now(), -12 * 60, :second)
          )

        :ok = CodeMySpecSpex.Fixtures.agent_said(scope, agent, "reading the existing exporter")
        :ok = CodeMySpecSpex.Fixtures.age_agent_messages(scope, agent, 10 * 60)

        # Opened and never closed. A long reasoning turn produces nothing
        # observable until it lands, which is the whole difficulty.
        :ok = CodeMySpecSpex.Fixtures.start_turn(scope, agent.id)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "the work in flight is visible and the silence is not a stall",
            context do
        line = in_flight_line(context.view)

        assert line, "the view has no notion of work in flight at all:\n#{context.view}"

        refute line =~ ~r/nothing|none|no turn/i,
               """
               The turn still in progress is reported as nothing in flight.

               Asserting that the phrase "in flight" appears somewhere is not
               enough: every agent carries that label whether or not a turn is
               open, so the check passes with the fact missing. What matters is
               what the line says.

               in flight: #{line}
               """

        refute context.view =~ ~r/\b(stalled|stuck|dead|not responding|stopped)\b/i,
               """
               A ten-minute silence with an open turn is being read as a stall.

               This is the expensive mistake on this story. The remedy for a
               stall is a restart, and restarting here discards a turn that is
               still arriving, wastes the model spend, and starts the same work
               from the beginning — so the fix makes the thing it was meant to
               fix take longer, and does it again next time.

               A view can surface in-flight work correctly — criterion 3297 —
               and still lead with a verdict computed from a silence threshold
               that never consults it. That is why this criterion needs both
               conditions at once.

               view:
               #{context.view}
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
