defmodule CodeMySpecSpex.Story1080.Criterion2164Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2164 — A work offer is accepted by starting its task — calling
  start_task on it, resuming one the agent already held included.
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

  spex "Starting the offered task accepts and closes the offer", criterion: 2164 do
    scenario "a coder calls start_task on the task it was offered" do
      given_ "a coder has an open work offer for a task", context do
        {:ok, offered_work(context)}
      end

      when_ "it calls start_task on that task", context do
        context = start_agent_task(context, context.coder, next_task(context, context.coder))
        {:ok, context}
      end

      then_ "the offer is accepted and closed", context do
        assert [%{status: "claimed"}] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end
end
