defmodule CodeMySpecSpex.Story1080.Criterion1818Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1818 — A work offer ignored once is offered again with more
  detail: why it matters, its prerequisites and where to read.
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

  spex "Work ignored once comes back with more detail", criterion: 1818 do
    scenario "a coder ends its turn without taking the work" do
      given_ "a coder offered work, mid-turn", context do
        {:ok, offered_work(context)}
      end

      when_ "it ends the turn without starting it, and is offered the work again", context do
        :ok = Fixtures.end_turn(context.scope, context.coder)
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
        {:ok, Map.put(context, :prompt, prompt)}
      end

      then_ "the second offer says why it matters, what it follows and where to read", context do
        assert context.prompt =~ "did not take it", context.prompt
        assert context.prompt =~ "Why it matters:", context.prompt
        assert context.prompt =~ "It follows `bdd_specs_exist`", context.prompt
        assert context.prompt =~ "Where to read:", context.prompt
        assert context.prompt =~ "reject_offer", context.prompt
        {:ok, context}
      end

      then_ "and it is recorded as the second attempt", context do
        assert [%{attempt: 2, status: "open"} | _] =
                 offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end
end
