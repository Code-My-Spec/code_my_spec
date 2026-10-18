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

  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
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
        {:ok, context}
      end

      when_ "it calls tap_out on that task", context do
        {:reply, reply, _} =
          TapOut.execute(
            %{task_id: context.task_id, reason: "I should not be the one to do this"},
            agent_frame(context, context.coder)
          )

        refute reply.isError, response_text(reply)
        {:ok, context}
      end

      then_ "the offer is not settled as declined", context do
        refute Enum.any?(offers(context, context.coder, %{kind: "work"}), &(&1.status == "declined")),
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
end
