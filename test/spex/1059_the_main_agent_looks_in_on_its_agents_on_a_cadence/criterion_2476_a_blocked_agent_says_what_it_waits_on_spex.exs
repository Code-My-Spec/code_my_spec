defmodule CodeMySpecSpex.Story1059.Criterion2476Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 2476 — A blocked agent's entry says what it is waiting on.

  "blocked; inspect the waiting work" sent main to read the agent's
  conversation to learn what it was waiting on — every time, for an answer the
  digest already holds: the question that blocked the task.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A blocked agent's entry names what blocked it", criterion: 2476 do
    scenario "a coder blocks its task on a question" do
      given_ "a main agent and a coding agent holding a task", context do
        context = given_a_staffed_checkout(context, "spex_2476")
        # A coder's question goes to main; with no main it is someone else's and
        # the check-in counts it instead of listing the agent.
        _main = Fixtures.running_agent(context.scope, role: "main")
        coding = Fixtures.running_agent(context.scope, role: "coding")
        {coding, task} = Fixtures.agent_task_fixture(context.scope, coding)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        {:ok, Map.merge(context, %{coding: coding, task_id: task.id, coding_frame: frame})}
      end

      when_ "it asks a question that blocks the task, and main checks in", context do
        response =
          ToolLibrary.run(
            "ask_question",
            %{
              task_id: context.task_id,
              questions: [
                %{
                  question: "Should we retain the old column?",
                  options: [%{label: "Retain"}, %{label: "Remove"}]
                }
              ]
            },
            Map.put(context.coding_frame.assigns, :scope, context.scope)
          )

        assert match?({:ok, _}, response), response_text(response)
        {:ok, Compact.report(context)}
      end

      then_ "its entry says it is waiting on that question", context do
        line =
          context.report
          |> Compact.needs_you()
          |> String.split("\n")
          |> Enum.find("", &String.contains?(&1, context.coding.id))

        assert line =~ "Should we retain the old column?",
               """
               The agent's entry should say what it is waiting on.

               Needs you:
               #{Compact.needs_you(context.report)}
               """

        refute line =~ "inspect the waiting work",
               "That is the line this replaces.\n\n#{line}"

        {:ok, context}
      end
    end
  end
end
