defmodule CodeMySpecSpex.Story1046.Criterion2553Spex do
  @moduledoc """
  Story 1046 — Promotion publishes verified work to the development branch.
  Criterion 2553 — Plain code certified clean at its HEAD is queued.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Plain code certified clean at its HEAD is queued", criterion: 2553 do
    scenario "Main promotes a clean, certified commit with nothing assigned" do
      given_ "Main's copy has committed work and no story or issue assigned", context do
        context = a_promotable_project(context)

        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":tidier")
        )

        {:ok, context}
      end

      given_ "compiler, credo, and tests certified that exact HEAD with no findings", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "Main promotes without naming a story or issue", context do
        {:ok, Map.put(context, :response, promote(context, nil))}
      end

      then_ "the candidate is queued", context do
        text = response_text(context.response)
        refute context.response.isError, text
        assert text =~ "Queued for promotion", text
        {:ok, context}
      end
    end
  end
end
