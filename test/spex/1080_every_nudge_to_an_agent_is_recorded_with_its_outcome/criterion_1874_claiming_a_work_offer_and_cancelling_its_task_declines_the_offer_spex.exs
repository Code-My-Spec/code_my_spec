defmodule CodeMySpecSpex.Story1080.Criterion1874Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1874 — Claiming a work offer and then cancelling its task settles
  the offer as declined, so the escalation ladder does not reset.

  7169d3cf: metric_flow QA claimed and cancelled `qa_journey_wallaby` and was
  handed it straight back, over and over. A claim resets the ladder; a claim
  that is cancelled must not.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.IdleAgentHelpers, only: [start_agent_task: 3]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A claim that is cancelled is a decline", criterion: 1874 do
    scenario "a coder starts the offered work and cancels it" do
      given_ "a coder offered work, mid-turn", context do
        {:ok, offered_work(context)}
      end

      when_ "it starts the work, cancels the task and ends its turn", context do
        task = next_task(context, context.coder)
        context = start_agent_task(context, context.coder, task)
        task_id = held_task_id(context, context.coder)

        cancelled =
          ToolLibrary.run(
            "cancel_task",
            %{task_id: task_id},
            Map.put(
              agent_frame(context, context.coder).assigns,
              :scope,
              agent_frame(context, context.coder).assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, cancelled), response_text(cancelled)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the work offer is declined, not claimed", context do
        assert [%{status: "declined", reason: "claimed and cancelled"} | _] =
                 context
                 |> offers(context.coder, %{kind: "work"})
                 |> Enum.reverse(),
               listing(context)

        {:ok, context}
      end
    end
  end
end
