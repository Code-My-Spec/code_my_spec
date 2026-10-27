defmodule CodeMySpecSpex.Story1167.Criterion2508Spex do
  @moduledoc """
  Story 1167, criterion 2508: A change to one context selects the tests and
  spex that reach it without selecting unrelated files.

  The baseline is a green run on the gate device. The selection itself is
  produced by the promotion gate, never supplied by this scenario.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @flakes "lib/code_my_spec/analysis/flakes.ex"
  @flakes_test "test/code_my_spec/analysis/flakes_test.exs"
  @flakes_spex "test/spex/1164_flake_detection/criterion_1_flakes_spex.exs"
  @unrelated_test "test/code_my_spec/accounts_test.exs"
  @unrelated_spex "test/spex/1166_promotion_timing/criterion_1_timing_spex.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A change to one context selects its tests and the spex that reach it",
    criterion: 2508 do
    scenario "the gate records a narrow selection for a changed Flakes context" do
      given_ "a green gate baseline with related and unrelated tests and spex", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        Fixtures.green_test_impact_baseline(context.scope, context.gate,
          source: @flakes,
          related: [@flakes_test, @flakes_spex],
          unrelated: [@unrelated_test, @unrelated_spex]
        )

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "the promotion changes only the Flakes context", context do
        commit_work(
          context,
          context.agent_root,
          @flakes,
          "defmodule CodeMySpec.Analysis.Flakes do\n  def confirmed?, do: true\nend\n"
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes and the gate answers its full runs", context do
        response = promote(context, context.story.number)
        refute response.isError
        the_gate_answers(context)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "the recorded selection contains the test and spex that reach Flakes", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selection'][data-mode='partial']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@flakes_test}']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@flakes_spex}']"
               )

        {:ok, context}
      end

      then_ "the recorded selection excludes unrelated tests and spex", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selection'][data-mode='partial']"
               )

        refute has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@unrelated_test}']"
               )

        refute has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@unrelated_spex}']"
               )

        {:ok, context}
      end
    end
  end
end
