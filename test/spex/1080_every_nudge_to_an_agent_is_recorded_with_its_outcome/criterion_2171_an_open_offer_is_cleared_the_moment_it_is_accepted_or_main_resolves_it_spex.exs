defmodule CodeMySpecSpex.Story1080.Criterion2171Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2171 — An open offer is cleared the moment it is accepted or
  main resolves it, so the agent can be offered its next work without a
  refusal.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
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

  spex "Accepting an offer clears it so the next one is not refused", criterion: 2171 do
    scenario "a coder starts the offered task, then is offered its next work" do
      given_ "a coder has an open work offer for a task", context do
        {:ok, offered_work(context)}
      end

      when_ "it accepts by starting the task, and the harness looks at its work again", context do
        context = start_agent_task(context, context.coder, next_task(context, context.coder))
        :ok = Fixtures.end_turn(context.scope, context.coder)
        context = put_to_work(context)
        {:ok, context}
      end

      then_ "the accepted offer is closed at once", context do
        assert [%{status: "claimed"} | _] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end

      then_ "and the agent can be offered its next work without a refusal", context do
        id = context.coder

        receive do
          {:work_turn_requested, ^id, _ref, _prompt} -> :ok
        after
          2_000 -> flunk("no next offer followed the cleared one")
        end

        {:ok, context}
      end
    end
  end
end
