defmodule CodeMySpecSpex.Story1167.Criterion2510Spex do
  @moduledoc "Story 1167, criterion 2510: changing config selects the whole suite."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @config "config/config.exs"
  @source "lib/code_my_spec/analysis/flakes.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A change to config/config.exs selects the whole suite", criterion: 2510 do
    scenario "the gate records a full selection and names the config change" do
      given_ "a promotable project with a green gate baseline", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        Fixtures.green_test_impact_baseline(context.scope, context.gate,
          related: ["test/code_my_spec/analysis/flakes_test.exs"],
          unrelated: ["test/code_my_spec/accounts_test.exs"]
        )

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "the promotion changes config/config.exs and a lib file", context do
        commit_work(
          context,
          context.agent_root,
          @config,
          "import Config\nconfig :code_my_spec, :impact_probe, true\n"
        )

        commit_work(
          context,
          context.agent_root,
          @source,
          "defmodule CodeMySpec.Analysis.Flakes do\n  def confirmed?, do: true\nend\n"
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the promotion is gated", context do
        response = promote(context, context.story.number)
        refute response.isError
        the_gate_answers(context)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "the recorded selection covers the whole suite", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selection'][data-mode='full']"
               )

        {:ok, context}
      end

      then_ "the promotion says the config change caused the full selection", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selection-reason']",
                 @config
               )

        {:ok, context}
      end
    end
  end
end
