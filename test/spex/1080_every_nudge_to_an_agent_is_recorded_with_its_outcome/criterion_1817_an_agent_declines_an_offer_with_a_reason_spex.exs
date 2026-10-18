defmodule CodeMySpecSpex.Story1080.Criterion1817Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1817 — An agent declines an offer with a reason; the offer
  settles as declined with that reason, and main is told.

  The 1118 `story_promoted` repeats: work already done, offered again, and the
  only way out was a task-less `tap_out` that counted as ignoring it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Declining an offer settles it as declined and tells main", criterion: 1817 do
    scenario "a coder rejects work it should not take" do
      given_ "a coder offered work, mid-turn, and a main", context do
        context = offered_work(context)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      when_ "it rejects the offer with its reason", context do
        reason = "already promoted at v2.0.307"

        :ok =
          Fixtures.agent_tool_call(context.scope, %{id: context.coder}, "r1", "reject_offer", %{
            "reason" => reason
          })

        {:reply, reply, _} =
          LocalServer.handle_tool_call(
            "reject_offer",
            %{reason: reason},
            agent_frame(context, context.coder)
          )

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :reason, reason)}
      end

      then_ "the offer settles as declined with that reason", context do
        assert [%{status: "declined", reason: reason}] =
                 offers(context, context.coder, %{kind: "work"}),
               listing(context)

        assert reason == context.reason
        {:ok, context}
      end

      then_ "and main is told, with the reason", context do
        assert Enum.any?(
                 offers(context, context.main_id, %{kind: "stalled"}),
                 &(&1.subject == "agent:#{context.coder}" and
                     Enum.any?(&1.messages, fn m ->
                       m =~ "Offer declined" and m =~ context.reason
                     end))
               ),
               listing(context)

        {:ok, context}
      end
    end
  end
end
