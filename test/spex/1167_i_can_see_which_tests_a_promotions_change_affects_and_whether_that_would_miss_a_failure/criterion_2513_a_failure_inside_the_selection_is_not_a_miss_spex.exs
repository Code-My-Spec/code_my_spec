defmodule CodeMySpecSpex.Story1167.Criterion2513Spex do
  @moduledoc "Story 1167, criterion 2513: a selected failure is not a miss."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @source "lib/code_my_spec/analysis/flakes.ex"
  @selected_test "test/code_my_spec/analysis/flakes_test.exs"
  @unrelated_test "test/code_my_spec/accounts_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A failure inside the selection is not a miss", criterion: 2513 do
    scenario "the gate records the selected failing test without a miss" do
      given_ "a promotion whose change selects flakes_test.exs", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        Fixtures.green_test_impact_baseline(context.scope, context.gate,
          source: @source,
          related: [@selected_test],
          unrelated: [@unrelated_test]
        )

        story = a_promotable_story(context)

        commit_work(
          context,
          context.agent_root,
          @source,
          "defmodule CodeMySpec.Analysis.Flakes do\n  def confirmed?, do: true\nend\n"
        )

        {:ok, context |> Map.put(:story, story) |> analyzers_are_current()}
      end

      when_ "the full gate run fails flakes_test.exs", context do
        Fixtures.fail_full_promotion_run(context.gate, @selected_test)
        response = promote(context, context.story.number)
        refute response.isError
        the_gate_answers(context)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "the selection contains flakes_test.exs", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@selected_test}']"
               )

        {:ok, context}
      end

      then_ "the failed selected test has no miss record", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-failed-test'][data-file='#{@selected_test}']"
               )

        refute has_element?(
                 context.timing_view,
                 "[data-test='promotion-miss'][data-file='#{@selected_test}']"
               )

        {:ok, context}
      end
    end
  end
end
