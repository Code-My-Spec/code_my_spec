defmodule CodeMySpecSpex.Story1080.Criterion2158Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2158 — An offer that asks an agent to act names itself and the way
  to refuse it: the message carries the offer's id, and tells the agent to
  complete it if it can, or to call reject_offer with that id and a reason.
  """

  use CodeMySpecSpex.Case

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

  spex "A work offer names its id and how to refuse it", criterion: 2158 do
    scenario "work is offered to a coder" do
      given_ "coding work is waiting", context do
        {:ok, coding_work_waiting(context)}
      end

      when_ "it is offered to a continuous coder", context do
        context = push_waiting_work(context)
        [offer] = offers(context, context.coder, %{kind: "work"})
        {:ok, Map.put(context, :offer, offer)}
      end

      then_ "the message carries the offer's id", context do
        assert context.prompt =~ context.offer.id, context.prompt
        {:ok, context}
      end

      then_ "and tells the agent to complete it or call reject_offer with that id and a reason",
            context do
        assert context.prompt =~ "reject_offer", context.prompt
        {:ok, context}
      end
    end
  end
end
