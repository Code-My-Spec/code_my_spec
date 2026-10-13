defmodule CodeMySpecSpex.Story1046.Criterion1971Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1971 — Only the queue lands work.

  Rule: an agent's `promote` records its copy and commit and moves nothing.
  Main moves only when the queue lands a gated batch.
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

  spex "Only the queue lands work; agents enqueue", criterion: 1971 do
    scenario "an agent promotes, and the queue lands it" do
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

        context =
          context
          |> Map.put(:story, a_promotable_story(context))
          |> Map.put(:main_before, head_of(context, context.running_root))
          |> Map.put(:copy_before, head_of(context, context.agent_root))

        {:ok, context}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "the promote moved neither main nor the agent's copy", context do
        assert response_text(context.response) =~ "Queued for promotion"
        assert head_of(context, context.running_root) == context.main_before
        assert head_of(context, context.agent_root) == context.copy_before
        {:ok, context}
      end

      when_ "the gate's analyzers answer clean", context do
        the_gate_answers(context)
        {:ok, Map.put(context, :told, what_the_agent_was_told(context))}
      end

      then_ "the queue has landed it on main", context do
        assert context.told =~ "landed on main", context.told
        refute head_of(context, context.running_root) == context.main_before
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/peace.ex")
        {:ok, context}
      end
    end
  end

  defp peace,
    do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def sue, do: :sued\nend\n"
end
