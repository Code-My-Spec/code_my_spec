defmodule CodeMySpecSpex.Story1167.Criterion2512Spex do
  @moduledoc "Story 1167, criterion 2512: an omitted full-run failure is a named miss."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @source "lib/code_my_spec/promotion_queue/worker.ex"
  @selected_test "test/code_my_spec/promotion_queue/worker_test.exs"
  @omitted_test "test/code_my_spec/agents/waiting_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A full run fails a test the selection left out, and John sees a miss naming the test and the changed files",
    criterion: 2512 do
    scenario "the gate records an omitted failure with its test and changed source" do
      given_ "a green gate baseline relating worker.ex to its own test but not waiting_test.exs",
             context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        Fixtures.green_test_impact_baseline(context.scope, context.gate,
          source: @source,
          related: [@selected_test],
          unrelated: [@omitted_test]
        )

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "the promotion changes worker.ex and the full gate run will fail waiting_test.exs",
             context do
        commit_work(
          context,
          context.agent_root,
          @source,
          "defmodule CodeMySpec.PromotionQueue.Worker do\n  def impact_probe, do: :changed\nend\n"
        )

        Fixtures.fail_full_promotion_run(context.gate, @omitted_test)
        {:ok, context |> certify_current_story() |> analyzers_are_current()}
      end

      when_ "the promotion is gated and John opens promotion timing", context do
        response = promote(context, context.story.number, fresh: true)
        refute response.isError
        the_gate_answers(context)
        what_the_agent_was_told(context)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "waiting_test.exs is outside the recorded selection", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selection'][data-mode='partial']"
               )

        refute has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@omitted_test}']"
               )

        {:ok, context}
      end

      then_ "the miss names waiting_test.exs and the changed worker.ex", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-miss'][data-file='#{@omitted_test}']",
                 "worker.ex"
               )

        {:ok, context}
      end
    end
  end
end
