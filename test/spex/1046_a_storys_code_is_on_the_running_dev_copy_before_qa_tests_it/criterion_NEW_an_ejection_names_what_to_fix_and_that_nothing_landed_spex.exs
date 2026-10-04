defmodule CodeMySpecSpex.Story1046.CriterionNewAnEjectionNamesWhatToFixSpex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion NEW (replaces 1375) — An ejection names what to fix and that
  nothing landed.

  Rule: a candidate taken out of the queue is told, in one message, that none
  of its work reached main, each finding against it, and that the next step is
  to fix them and promote again.
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

  spex "An ejection names what to fix and that nothing landed" do
    scenario "the gate's credo finds two IO.inspect calls in the story's new module" do
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

      when_ "the agent promotes, and the gate's credo reports two findings", context do
        promote(context, context.story.number)

        the_gate_answers(context, %{
          "credo" => [
            io_inspect("lib/broken_oaths/diplomacy/peace.ex", 2),
            io_inspect("lib/broken_oaths/diplomacy/peace.ex", 3)
          ]
        })

        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "it is told nothing of its work landed", context do
        assert context.told =~ "nothing of it landed", context.told
        refute exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex")
        {:ok, context}
      end

      then_ "it is told each finding, where it is", context do
        assert context.told =~ "peace.ex:2", context.told
        assert context.told =~ "peace.ex:3", context.told
        assert context.told =~ "IO.inspect", context.told
        {:ok, context}
      end

      then_ "it is told to fix them and promote again", context do
        assert context.told =~ "Fix them and promote again", context.told
        {:ok, context}
      end
    end
  end

  # Credo's own JSON keys, as a harness relays them; a high-priority warning.
  defp io_inspect(file, line),
    do: %{
      "filename" => file,
      "line_no" => line,
      "priority" => 10,
      "category" => "warning",
      "check" => "Credo.Check.Warning.IoInspect",
      "message" => "There should be no calls to `IO.inspect/1`."
    }

  defp peace,
    do: """
    defmodule BrokenOaths.Diplomacy.Peace do
      def sue, do: IO.inspect(:sued)
      def plead, do: IO.inspect(:pleaded)
    end
    """
end
