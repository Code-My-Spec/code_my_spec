defmodule CodeMySpecSpex.Story1046.Criterion2554Spex do
  @moduledoc """
  Story 1046 — Promotion publishes verified work to the development branch.
  Criterion 2554 — A credo finding refuses the promotion before it reaches the gate.
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

  spex "A credo finding refuses promotion before the gate", criterion: 2554 do
    scenario "Main promotes unassigned work with a credo warning at HEAD" do
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

      given_ "its current certification found a credo warning", context do
        analyzers_are_current(context)

        {:ok, _problem} =
          Fixtures.record_problem(context.scope, "credo", %{
            file_path: "lib/code_my_spec/hooks/stop.ex",
            message: "Logger metadata key cms_started_ms not found in Logger config",
            severity: :warning
          })

        {:ok, context}
      end

      when_ "Main promotes without naming a story or issue", context do
        {:ok, Map.put(context, :response, promote(context, nil))}
      end

      then_ "promotion is refused with the finding before it is queued", context do
        text = response_text(context.response)
        assert context.response.isError, text
        assert text =~ "cms_started_ms", text
        refute text =~ "Queued for promotion", text
        {:ok, context}
      end
    end
  end
end
