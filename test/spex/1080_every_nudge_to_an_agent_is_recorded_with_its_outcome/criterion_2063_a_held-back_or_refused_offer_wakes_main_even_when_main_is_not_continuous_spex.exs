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
        main_id = context.main_id
        assert_receive {:work_turn_requested, ^main_id, _ref, prompt}, 2_000
        assert prompt =~ context.coder, prompt
        {:ok, context}
      end
    end
  end
end
