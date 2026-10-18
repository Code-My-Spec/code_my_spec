defmodule CodeMySpecSpex.Story1080.Criterion2056Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2056 — An offer held back from an agent reaches main as one
  escalation naming the agent, what it would not take and its reason, so
  main can reassign, cancel or answer it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers

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

  spex "A held-back offer reaches main as one escalation", criterion: 2056 do
    scenario "a coder declines its work offer with a reason" do
      given_ "a coder offered work, and a continuous main mid-turn", context do
        context = offered_work(context)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      when_ "it declines the offer with its reason", context do
        reason = "already promoted at v2.0.307"

        {:reply, reply, _} =
          LocalServer.handle_tool_call(
            "reject_offer",
            %{reason: reason},
            agent_frame(context, context.coder)
          )

        refute reply.isError
        {:ok, Map.put(context, :reason, reason)}
      end

      then_ "main gets one escalation naming the agent, what it would not take and its reason",
            context do
        main_id = context.main_id
        coder = context.coder

        assert_receive {:agent_dispatch, ^main_id, _ref, notice}, 2_000
        assert notice =~ coder, notice
        assert notice =~ context.reason, notice
        {:ok, context}
      end

      then_ "and it is not escalated again at the next turn end", context do
        main_id = context.main_id
        :ok = Fixtures.put_agent_mid_turn(context.scope, main_id)
        :ok = Fixtures.end_turn(context.scope, main_id)
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = Fixtures.end_turn(context.scope, context.coder)

        receive do
          {:agent_dispatch, ^main_id, _ref, repeat} ->
            refute repeat =~ context.reason, "the held-back offer was escalated twice"
        after
          500 -> :ok
        end

        {:ok, context}
      end
    end
  end
end
