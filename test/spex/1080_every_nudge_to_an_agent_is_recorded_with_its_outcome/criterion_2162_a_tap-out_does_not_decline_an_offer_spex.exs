defmodule CodeMySpecSpex.Story1080.Criterion2162Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2162 — A tap-out does not decline an offer: it stays open on the
  agent until it is accepted, refused with reject_offer, or resolved by
  main.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Tapping out of a task does not decline the offer on it", criterion: 2162 do
    scenario "a coder holding an open work offer calls tap_out on that task" do
      given_ "a coder has an open work offer for a task", context do
        context = offered_work(context)
        context = start_agent_task(context, context.coder, next_task(context, context.coder))
        {:ok, Map.put(context, :task_id, held_task_id(context, context.coder))}
      end

      when_ "it calls tap_out on that task", context do
        reply =
          ToolLibrary.run(
            "tap_out",
            %{task_id: context.task_id, reason: "I should not be the one to do this"},
            tool_context(agent_frame(context, context.coder))
          )

        assert match?({:ok, _}, reply), response_text(reply)
        {:ok, context}
      end

      then_ "the offer is not settled as declined", context do
        refute Enum.any?(
                 offers(context, context.coder, %{kind: "work"}),
                 &(&1.status == "declined")
               ),
               listing(context)

        {:ok, context}
      end

      then_ "it stays open on the agent", context do
        assert Enum.any?(offers(context, context.coder, %{kind: "work"}), &(&1.status == "open")),
               listing(context)

        {:ok, context}
      end
    end
  end

  # A tool runs from a frame's assigns, with the scope under the key ToolLibrary reads.
  defp tool_context(%{assigns: assigns}), do: Map.put(assigns, :scope, assigns[:current_scope])
end
