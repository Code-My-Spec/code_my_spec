defmodule CodeMySpecSpex.Story1080.Criterion1804Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1804 — The declined-offer damper suppresses a work offer: once an
  agent has declined a piece of work with a reason, the harness does not
  offer that same work to it again (criteria 2055, 2163) — no offer is sent,
  and none is recorded.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1]
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A declined work offer is not sent again", criterion: 1804 do
    scenario "the harness would otherwise offer the same declined work again" do
      given_ "a coder declined a work offer with a reason", context do
        context = offered_work(context)

        :ok =
          Fixtures.agent_tool_call(
            context.scope,
            %{id: context.coder},
            "r1",
            "reject_offer",
            %{"reason" => "already promoted at v2.0.307"}
          )

        {:reply, _reply, _} =
          LocalServer.handle_tool_call(
            "reject_offer",
            %{reason: "already promoted at v2.0.307"},
            agent_frame(context, context.coder)
          )

        assert [%{status: "declined"}] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      when_ "the harness looks at that copy's work again", context do
        context = put_to_work(context)
        id = context.coder

        receive do
          {:work_turn_requested, ^id, _ref, _prompt} ->
            flunk("declined work was offered again")
        after
          1_000 -> :ok
        end

        {:ok, context}
      end

      then_ "no offer is sent, and the declined one is the only one recorded", context do
        assert [%{status: "declined"}] = offers(context, context.coder, %{kind: "work"}),
               "the damper let a new offer through:\n" <> listing(context)

        {:ok, context}
      end
    end
  end
end
