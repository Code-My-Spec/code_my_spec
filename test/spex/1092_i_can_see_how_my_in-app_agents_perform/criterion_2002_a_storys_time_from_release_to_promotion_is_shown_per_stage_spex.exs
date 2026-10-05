defmodule CodeMySpecSpex.Story1092.Criterion2002Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2002 -- A story's time from release to promotion is shown per
  stage.

  Rule: Each team's stories show cycle time from release to promotion,
  broken down by stage.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A promoted story's total release-to-promotion time is broken down by stage",
       criterion: 2002 do
    scenario "a story a team took from release to promotion" do
      given_ "a story released an hour before its team promoted it", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context, title: "Released then promoted")
        :ok = Fixtures.age_story(context.scope, story.id, 3600)
        context = analyzers_are_current(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "its team promotes it", context do
        response = promote(context, context.story.number)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "I see its total time from release to promotion", context do
        {:ok, _index, html} = live(context.conn, index_path(context))

        assert html =~ context.story.title,
               "the promoted story does not appear in the performance report at all"

        assert html =~ "1h" or html =~ "60",
               "the story's total release-to-promotion time does not reflect the hour it actually took"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and how much of it went to specs, build, certification, QA and promotion", context do
        for stage <- ~w(specs build certification QA promotion) do
          assert context.html =~ stage,
                 "the story's stage breakdown is missing the #{stage} stage"
        end

        {:ok, context}
      end
    end
  end
end
