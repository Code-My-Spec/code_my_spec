defmodule CodeMySpecSpex.Story1080.Criterion2160Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2160 — A role that declined a requirement is not offered it again
  in a loop: while a declined offer for it stands, main is not told the
  agent stalled either, because the declined offer already says what is
  going on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1]
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A declined requirement is not offered again while the decline stands", criterion: 2160 do
    scenario "a coding agent declines its offer and the requirement is still unsatisfied" do
      given_ "a coder declined its work offer with a reason", context do
        context = offered_work(context)

        :ok =
          Fixtures.agent_tool_call(
            context.scope,
            %{id: context.coder},
            "r1",
            "reject_offer",
            %{"reason" => "not mine to resolve"}
          )

        {:reply, _reply, _} =
          CodeMySpec.McpServers.LocalServer.handle_tool_call(
            "reject_offer",
            %{reason: "not mine to resolve"},
            agent_frame(context, context.coder)
          )

        assert [%{status: "declined"}] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      when_ "the stall check and the work offer run again, the requirement still unsatisfied",
            context do
        context = put_to_work(context)
        {:ok, context}
      end

      then_ "the agent is not offered it again while the declined offer stands", context do
        id = context.coder

        receive do
          {:work_turn_requested, ^id, _ref, _prompt} ->
            flunk("declined work was offered again while the decline stands")
        after
          1_000 -> :ok
        end

        assert [%{status: "declined"}] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end

      then_ "main is not told the agent stalled", context do
        refute Enum.any?(
                 offers(context, context.coder, %{kind: "stalled"}),
                 &(&1.subject == "agent:#{context.coder}")
               ),
               "the declined offer already says what is going on"

        {:ok, context}
      end
    end
  end
end
