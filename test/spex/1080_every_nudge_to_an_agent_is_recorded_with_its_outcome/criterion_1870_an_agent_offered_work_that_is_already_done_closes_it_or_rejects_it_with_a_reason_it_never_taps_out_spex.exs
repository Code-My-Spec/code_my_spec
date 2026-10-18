defmodule CodeMySpecSpex.Story1080.Criterion1870Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1870 — An agent offered work that is already done closes it or
  rejects it with a reason; it never taps out or leaves it open.

  `StartTask`'s `not_already_done/3`: when the requirement is found already
  satisfied, the system itself calls `Offers.close_stale/2` (status:
  declined, reason: "already satisfied") -- its own comment: "the system
  knows the offer is stale, so it does not wait for the agent to say so."
  The agent never has to call `reject_offer` or `tap_out` for this to happen.

  Per product's ruling: this needs one agent, not a race between two --
  "who did it doesn't matter to 1870". The work is satisfied directly
  (`FullSatisfactionFixtures.apply_qa_readiness_transition/1`) before the
  agent ever acts on it. Three separate `spex` blocks, not three `scenario`s
  in one: each `spex` gets its own fresh account/project/story, where
  multiple `scenario`s in one block would share a context and collide on
  the second's fixture setup (confirmed: "component already exists").
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Already-done work closes its own offer, without reject_offer or tap_out",
    criterion: 1870 do
    scenario "the work is satisfied before the coder ever acts on it" do
      given_ "a coder is offered work it has not yet claimed", context do
        context = offered_work(context)
        {:ok, Map.put(context, :work, next_task(context, context.coder))}
      end

      given_ "that work is satisfied, with no agent involved", context do
        {:ok, FullSatisfactionFixtures.apply_qa_readiness_transition(context)}
      end

      when_ "the coder calls start_task on that same, now-satisfied work", context do
        result =
          ToolLibrary.run(
            "start_task",
            context.work,
            tool_context(agent_frame(context, context.coder))
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "it is refused, told the work is already satisfied and its offer is closed",
            context do
        assert match?({:error, _}, context.result), response_text(context.result)
        assert response_text(context.result) =~ "already satisfied", response_text(context.result)

        assert response_text(context.result) =~ "the offer of it is closed",
               response_text(context.result)

        {:ok, context}
      end

      then_ "the offer settles declined with that reason, not left open", context do
        assert [%{status: "declined", reason: "already satisfied"}] =
                 offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  spex "The coder can reject an already-satisfied offer itself, with a reason",
    criterion: 1870 do
    scenario "the coder calls reject_offer instead of start_task" do
      given_ "a coder is offered work it has not yet claimed", context do
        context = offered_work(context)
        {:ok, Map.put(context, :work, next_task(context, context.coder))}
      end

      given_ "that work is satisfied, with no agent involved", context do
        {:ok, FullSatisfactionFixtures.apply_qa_readiness_transition(context)}
      end

      when_ "it calls reject_offer with a reason instead of start_task", context do
        assert {:ok, _text} =
                 ToolLibrary.run(
                   "reject_offer",
                   %{reason: "already satisfied"},
                   %{agent_id: context.coder, scope: context.scope}
                 )

        {:ok, context}
      end

      then_ "the offer settles declined with that reason", context do
        assert [%{status: "declined", reason: "already satisfied"}] =
                 offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  spex "Tapping out instead does not close or decline the already-satisfied offer",
    criterion: 1870 do
    scenario "the coder taps out instead of resolving the offer" do
      given_ "a coder is offered work it has not yet claimed", context do
        context = offered_work(context)
        {:ok, Map.put(context, :work, next_task(context, context.coder))}
      end

      given_ "that work is satisfied, with no agent involved", context do
        {:ok, FullSatisfactionFixtures.apply_qa_readiness_transition(context)}
      end

      when_ "it taps out instead of calling start_task, reject_offer, or anything else",
            context do
        reply =
          ToolLibrary.run(
            "tap_out",
            %{reason: "I should not be the one to do this"},
            tool_context(agent_frame(context, context.coder))
          )

        assert match?({:ok, _}, reply), response_text(reply)
        {:ok, context}
      end

      then_ "the offer is not settled as declined or closed; it stays open", context do
        assert [%{status: "open"}] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  # A tool runs from a frame's assigns, with the scope under the key ToolLibrary reads.
  defp tool_context(%{assigns: assigns}), do: Map.put(assigns, :scope, assigns[:current_scope])
end
