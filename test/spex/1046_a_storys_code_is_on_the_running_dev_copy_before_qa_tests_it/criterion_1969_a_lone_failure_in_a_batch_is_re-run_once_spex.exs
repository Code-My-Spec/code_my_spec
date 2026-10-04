defmodule CodeMySpecSpex.Story1046.Criterion1969Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1969 — A lone failure in a batch is re-run once.

  Rule: a batch red on exactly one finding re-runs that one analyzer before
  anything is taken out, because one failing test is as often a flake as a
  defect. Green on the re-run, the batch lands; red again, it is triaged.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A lone failure in a batch is re-run once", criterion: 1969 do
    scenario "one test fails in the gate, and passes when it is re-run" do
      given_ "a story branch main has moved past", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        analyzers_are_current(context)

        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      when_ "the agent promotes, and one test fails in the gate", context do
        promote(context, context.story.number)

        the_gate_answers(context, %{
          "exunit" => [
            %{
              "file" => "test/broken_oaths/diplomacy/treaty_test.exs",
              "line" => 7,
              "message" => "Assertion with == failed: timed out waiting for :signed"
            }
          ]
        })

        {:ok, context}
      end

      then_ "only that analyzer is run again", context do
        assert the_gate_is_running(context, ~w(exunit)) == ~w(exunit)
        {:ok, context}
      end

      when_ "the re-run passes", context do
        the_gate_answers(context, %{}, sources: ~w(exunit))
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the work lands", context do
        assert context.told =~ "landed on main", context.told
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex")
        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
