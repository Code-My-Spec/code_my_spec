defmodule CodeMySpecSpex.Story1167.Criterion2514Spex do
  @moduledoc "Story 1167, criterion 2514: a confirmed flake outside the selection is not a miss."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @source "lib/code_my_spec/promotion_queue/worker.ex"
  @selected_test "test/code_my_spec/promotion_queue/worker_test.exs"
  @flake_test "test/cms_harness/sync_path_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A flake outside the selection is not a miss", criterion: 2514 do
    scenario "a confirmed full-run flake outside the selection does not become a miss" do
      given_ "a promotion whose selection leaves out sync_path_test.exs", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        Fixtures.green_test_impact_baseline(context.scope, context.gate,
          source: @source,
          related: [@selected_test],
          unrelated: [@flake_test]
        )

        story = a_promotable_story(context)

        commit_work(
          context,
          context.agent_root,
          @source,
          "defmodule CodeMySpec.PromotionQueue.Worker do\n  def impact_probe, do: :changed\nend\n"
        )

        {:ok,
         context |> Map.put(:story, story) |> certify_current_story() |> analyzers_are_current()}
      end

      given_ "sync_path_test.exs fails in the full run", context do
        {:ok, context}
      end

      when_ "the failed test passes on the targeted rerun and John opens promotion timing",
            context do
        response = promote(context, context.story.number, fresh: true)
        refute response.isError

        the_gate_answers_and_passes_rerun(context, %{
          "exunit" => [
            %{
              "file" => @flake_test,
              "line" => 1,
              "name" => "test sync path",
              "message" => "test failure"
            }
          ]
        })

        what_the_agent_was_told(context)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "sync_path_test.exs is outside the recorded selection", context do
        refute has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@flake_test}']"
               )

        {:ok, context}
      end

      then_ "the failed test is classified as a flake with no miss", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-flake'][data-file='#{@flake_test}']"
               )

        refute has_element?(
                 context.timing_view,
                 "[data-test='promotion-miss'][data-file='#{@flake_test}']"
               )

        {:ok, context}
      end
    end
  end
end
