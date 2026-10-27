defmodule CodeMySpecSpex.Story1167.Criterion2509Spex do
  @moduledoc "Story 1167, criterion 2509: a newly added test is selected by the promotion gate."

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @new_test "test/code_my_spec/analysis/flakes_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A test file the promotion adds is always selected", criterion: 2509 do
    scenario "the gate includes a new test even without a baseline dependency edge" do
      given_ "a promotable project with a green gate baseline", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()

        Fixtures.green_test_impact_baseline(context.scope, context.gate,
          unrelated: ["test/code_my_spec/accounts_test.exs"]
        )

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "the promotion adds a test file absent from that baseline", context do
        commit_work(
          context,
          context.agent_root,
          @new_test,
          "defmodule CodeMySpec.Analysis.FlakesTest do\n  use ExUnit.Case\n  test \"a new test\" do\n    assert true\n  end\nend\n"
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

      then_ "the recorded selection includes the added test file", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-selected-test'][data-file='#{@new_test}']"
               )

        {:ok, context}
      end
    end
  end
end
