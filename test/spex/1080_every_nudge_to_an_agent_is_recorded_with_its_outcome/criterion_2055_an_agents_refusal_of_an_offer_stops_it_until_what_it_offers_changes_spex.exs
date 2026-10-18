defmodule CodeMySpecSpex.Story1080.Criterion2055Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2055 — An agent's refusal of an offer, with its reason, stops
  that offer to that agent until what it offers changes.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, start_session: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.StoryBoundHelpers, only: [issue_accepted: 2]

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

  spex "A refusal stops that offer until what is offered changes", criterion: 2055 do
    scenario "the same work is not offered again, but different work is" do
      given_ "coding work waiting, and a continuous coder that declines it with a reason",
             context do
        context = coding_work_waiting(context)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        context = Map.put(context, :coder, id)

        {:reply, reply, _} =
          LocalServer.handle_tool_call(
            "reject_offer",
            %{reason: "not mine to resolve"},
            agent_frame(context, id)
          )

        refute reply.isError
        assert [%{status: "declined"}] = offers(context, id, %{kind: "work"}), listing(context)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, context}
      end

      when_ "the harness looks at its work again, nothing about it changed", context do
        context = put_to_work(context)
        id = context.coder

        receive do
          {:work_turn_requested, ^id, _ref, _prompt} ->
            flunk("declined work was offered again unchanged")
        after
          1_000 -> :ok
        end

        {:ok, context}
      end

      when_ "a different piece of work becomes available for it", context do
        context = issue_accepted(context, context.story)
        context = put_to_work(context)
        {:ok, context}
      end

      then_ "it is offered that new work", context do
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        {:ok, context}
      end
    end
  end
end
