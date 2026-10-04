defmodule CodeMySpecSpex.Story1046.Criterion1963Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1963 — The batch gate runs every analyzer at the batch commit before it lands.

  Rule: the commit that lands is the commit the gate analyzed — main with the
  candidate merged onto it, in the gate's own checkout — and it lands only once
  every analyzer has answered for it.
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

  spex "The batch gate runs every analyzer at the batch commit before it lands",
    criterion: 1963 do
    scenario "a candidate main has moved past is merged onto main and gated there" do
      given_ "a story branch, and main with a commit the branch does not have", context do
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

      when_ "the agent promotes, and three of the four analyzers answer clean", context do
        promote(context, context.story.number)
        the_gate_answers(context, %{}, sources: ~w(compiler credo exunit))
        {:ok, context}
      end

      then_ "nothing has landed while one analyzer has not answered", context do
        refute exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex"),
               "the work landed before every analyzer had answered for it"

        {:ok, context}
      end

      when_ "the last analyzer answers clean", context do
        the_gate_answers(context, %{}, sources: ~w(spex))
        gated = head_of(context, context.gate_root)

        {:ok,
         context |> Map.put(:gated, gated) |> Map.put(:told, what_the_agent_was_told(context))}
      end

      then_ "the gated tree held main's work and the story's together", context do
        assert exists?(context.gate_root, "lib/broken_oaths/diplomacy/treaty.ex")
        assert exists?(context.gate_root, "lib/broken_oaths/diplomacy/peace.ex")
        {:ok, context}
      end

      then_ "the commit that landed is the commit the gate analyzed", context do
        assert context.told =~ "landed on main", context.told

        assert head_of(context, context.running_root) == context.gated,
               "main is not at the commit every analyzer answered for"

        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
