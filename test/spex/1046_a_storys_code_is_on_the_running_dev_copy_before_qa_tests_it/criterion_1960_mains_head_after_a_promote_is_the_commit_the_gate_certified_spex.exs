defmodule CodeMySpecSpex.Story1046.Criterion1960Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1960 — Main's HEAD after a promote is the commit the gate certified.

  Rule: a promotion lands the certified commit exactly — no merge commit, no
  version bump on top — so what main runs is what every analyzer answered
  for. A candidate level with main is certified on its own copy at its own
  HEAD, and that commit is main's HEAD afterwards. (A candidate main has
  moved past is certified at the batch commit in the gate; criterion 1963
  covers that commit landing.)
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Main's HEAD after a promote is the commit the gate certified", criterion: 1960 do
    scenario "a candidate level with main, certified on its own copy" do
      given_ "a story's work committed on the agent's copy, its analyzers current there",
             context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)

        context = Map.put(context, :certified, head_of(context, context.agent_root))

        {:ok, context}
      end

      when_ "the agent promotes, and the queue lands it", context do
        promote(context, context.story.number)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "main's HEAD is exactly the certified commit", context do
        assert context.told =~ "landed on main", context.told

        assert head_of(context, context.running_root) == context.certified,
               "main is not at the commit the analyzers answered for — something " <>
                 "was committed on top of it"

        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
