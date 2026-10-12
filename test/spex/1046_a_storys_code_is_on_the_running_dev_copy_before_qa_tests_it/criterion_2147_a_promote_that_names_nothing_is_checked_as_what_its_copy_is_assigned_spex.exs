defmodule CodeMySpecSpex.Story1046.Criterion2147Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 2147 — A promote that names nothing is checked as what its copy is
  assigned; with nothing assigned it is plain code.

  Rule (John, 2026-10-11): promotion is not coupled to stories — a refactor or
  a UI pass promotes with no story and no issue, and that is fine. What a copy
  is assigned is explicit, so a promote that names nothing is that assignment's
  promotion. Landing a team's story as plain code skipped its QA check and left
  it unstamped (story 1091).
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

  spex "A promote naming nothing is the promotion of the copy's story", criterion: 2147 do
    scenario "the copy holds a certified story QA has not passed" do
      given_ "a story assigned to the copy and certified, with no QA pass", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context, assigned?: true, qa: :certified)
        context = analyzers_are_current(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent promotes without naming a story", context do
        {:ok, Map.put(context, :response, promote(context, nil))}
      end

      then_ "it is refused as that story's promotion, for the QA it lacks", context do
        text = response_text(context.response)
        assert context.response.isError, text
        assert text =~ "story #{context.story.number} has not passed QA", text
        {:ok, context}
      end
    end
  end

  spex "A promote naming nothing, from a copy assigned nothing, is plain code",
    criterion: 2147 do
    scenario "a refactor on a copy with no story or issue" do
      given_ "a committed refactor on a copy with nothing assigned", context do
        context = a_promotable_project(context)

        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/war.ex",
          war(":tidier")
        )

        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes without naming a story", context do
        {:ok, Map.put(context, :response, promote(context, nil))}
      end

      then_ "it is queued", context do
        text = response_text(context.response)
        refute context.response.isError, text
        assert text =~ "Queued for promotion", text
        {:ok, context}
      end
    end
  end
end
