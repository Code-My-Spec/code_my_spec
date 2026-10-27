defmodule CodeMySpecSpex.Story1167.Criterion2511Spex do
  @moduledoc "Story 1167, criterion 2511: a missing gate baseline selects the whole suite."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @source "lib/code_my_spec/analysis/flakes.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "With no baseline on the gate's device, the whole suite is selected and the promotion says so",
    criterion: 2511 do
    scenario "the gate falls back to the whole suite when its device has no green-main baseline" do
      given_ "a promotable project with no green-main baseline on its gate device", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "a promotion changing one lib file", context do
        commit_work(
          context,
          context.agent_root,
          @source,
          "defmodule CodeMySpec.Analysis.Flakes do\n  def confirmed?, do: true\nend\n"
        )

        {:ok, context |> certify_current_story() |> analyzers_are_current()}
      end

      when_ "the promotion is gated", context do
        response = promote(context, context.story.number, fresh: true)
        refute response.isError
        the_gate_answers(context)
        what_the_agent_was_told(context)

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

      then_ "the promotion records that the gate device has no baseline", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selection-reason']",
                 "baseline"
               )

        {:ok, context}
      end
    end
  end
end
