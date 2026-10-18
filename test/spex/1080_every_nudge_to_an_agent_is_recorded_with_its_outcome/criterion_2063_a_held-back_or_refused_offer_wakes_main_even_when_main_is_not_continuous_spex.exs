defmodule CodeMySpecSpex.Story1080.Criterion2063Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2063 — A held-back or refused offer reaches main the moment it
  settles, waking main even when main is not continuous.
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

  spex "A refused offer wakes main even when main is not continuous", criterion: 2063 do
    scenario "a coder declines its offer while main is not continuous and idle" do
      given_ "a coder offered work, and a non-continuous, idle main", context do
        context = offered_work(context)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      when_ "it declines the offer with its reason", context do
        {:reply, reply, _} =
          LocalServer.handle_tool_call(
            "reject_offer",
            %{reason: "already promoted at v2.0.307"},
            agent_frame(context, context.coder)
          )

        refute reply.isError
        {:ok, context}
      end

      then_ "main is woken the moment it settles, not left for its next scheduled turn",
            context do
        # Wake.decide/3's own @not_continuous table maps :offer_held_back to
        # :wake (citing this criterion), so a held-back/refused report to
        # main travels the same transport call an operator's message does --
        # Agents.dispatch_message, not Work.offer_turn_with -- and arrives as
        # {:agent_dispatch, ...}, not {:work_turn_requested, ...} (which is
        # for work main could claim, not a report). That dispatch is what
        # wakes a non-continuous main: the same delivery an operator message
        # uses to start one of its turns.
        main_id = context.main_id
        assert_receive {:agent_dispatch, ^main_id, _ref, notice}, 2_000
        assert notice =~ context.coder, notice
        {:ok, context}
      end
    end
  end
end
