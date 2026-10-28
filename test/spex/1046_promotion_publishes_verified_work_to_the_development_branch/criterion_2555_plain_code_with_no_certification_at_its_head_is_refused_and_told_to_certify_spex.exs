defmodule CodeMySpecSpex.Story1046.Criterion2555Spex do
  @moduledoc """
  Story 1046 — Promotion publishes verified work to the development branch.
  Criterion 2555 — Plain code with no certification at its HEAD is refused and told to certify.
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

  spex "Plain code without certification at HEAD is refused", criterion: 2555 do
    scenario "Main promotes an unassigned commit without current analyzer runs" do
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

      given_ "the copy has no certification at that HEAD", context do
        # given: already true — `commit_work` created a new HEAD without recording analyzer runs.
        {:ok, context}
      end

      when_ "Main promotes without naming a story or issue", context do
        {:ok, Map.put(context, :response, promote(context, nil))}
      end

      then_ "promotion is refused and Main is told to certify the commit", context do
        text = response_text(context.response)
        assert context.response.isError, text
        assert text =~ "certif", text
        refute text =~ "Queued for promotion", text
        {:ok, context}
      end
    end
  end
end
