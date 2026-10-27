defmodule CodeMySpecSpex.Story1167.Criterion2549Spex do
  @moduledoc "Story 1167, criterion 2549: every real gate failure is accounted for."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @source "lib/code_my_spec/promotion_queue/worker.ex"
  @selected_failure "test/code_my_spec/promotion_queue/worker_test.exs"
  @omitted_failure "test/code_my_spec/agents/waiting_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "On main after landing, every failing test of a real gate run is in the selection, a miss or a flake",
    criterion: 2549 do
    scenario "the recorded gate accounts for both failing test files" do
      given_ "story 1167 has landed on main and a green gate baseline selects only the worker test",
             context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        Fixtures.story_landed_on_main(context.scope, 1167)

        Fixtures.green_test_impact_baseline(context.scope, context.gate,
          source: @source,
          related: [@selected_failure],
          unrelated: [@omitted_failure]
        )

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "a real full gate run fails the selected worker test and the omitted waiting test",
             context do
        commit_work(
          context,
          context.agent_root,
          @source,
          "defmodule CodeMySpec.PromotionQueue.Worker do\n  def impact_probe, do: :changed\nend\n"
        )

        Fixtures.fail_full_promotion_run(context.gate, [@selected_failure, @omitted_failure])
        {:ok, analyzers_are_current(context)}
      end

      when_ "John opens the promotion's recorded selection, misses and flakes after its real gate run",
            context do
        response = promote(context, context.story.number)
        refute response.isError
        the_gate_answers(context)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "each of the two failing files is selected, a miss or a flake", context do
        for file <- [@selected_failure, @omitted_failure] do
          assert Enum.any?(
                   ["promotion-selected-test", "promotion-miss", "promotion-flake"],
                   fn category ->
                     has_element?(
                       context.timing_view,
                       "[data-test='#{category}'][data-file='#{file}']"
                     )
                   end
                 ),
                 "gate failure #{file} was not accounted for"
        end

        {:ok, context}
      end
    end
  end
end
