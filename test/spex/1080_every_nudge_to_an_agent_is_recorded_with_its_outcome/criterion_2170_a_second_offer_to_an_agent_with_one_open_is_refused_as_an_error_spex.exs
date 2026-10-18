defmodule CodeMySpecSpex.Story1080.Criterion2170Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2170 — A second offer to an agent with one open is refused as an
  error: not sent, not queued, and the refusal names the agent, the open
  offer and the offer attempted.
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

  spex "A second offer while one is open is refused, not queued", criterion: 2170 do
    scenario "the harness attempts a second offer while a fresh one stands open" do
      given_ "a coder has a fresh, unaged open work offer", context do
        {:ok, offered_work(context)}
      end

      when_ "the harness attempts a second such offer to it right away", context do
        :ok = Fixtures.put_to_work(context.scope)
        {:ok, context}
      end

      then_ "the second offer is refused: not sent, and not recorded alongside the first",
            context do
        id = context.coder

        receive do
          {:work_turn_requested, ^id, _ref, _prompt} ->
            flunk("a second offer was sent while the first was still open")
        after
          1_000 -> :ok
        end

        assert [%{status: "open"}] = offers(context, context.coder, %{kind: "work"}),
               "a second offer was queued alongside the open one:\n" <> listing(context)

        {:ok, context}
      end
    end
  end
end
