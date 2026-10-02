defmodule CodeMySpecSpex.Story70.Criterion1621Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1621 — A component nested under a context in the proposal gets that context as its parent.

  Components as records, step 2 (3aeb66cf): executing a proposal writes the graph as
  records — components, parents and dependencies — and no spec file.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp story(context) do
    StoryHelpers.create_story(context.scope,
      title: "A feature",
      description: "Needs a feature",
      acceptance_criteria: ["It works"]
    )
  end

  spex "A component nested under a context in the proposal gets that context as its parent",
    criterion: 1621 do
    scenario "a schema under a context" do
      given_ "a story for the surface component to carry", context do
        {:ok, Map.put(context, :story, story(context))}
      end

      when_ "the architect executes a proposal nesting a schema under Feature", context do
        execute_proposal!(
          context,
          proposal(context, context.story.number, [{"Feature", [{"Item", "schema"}]}], [
            {"FeatureLive", "Feature"}
          ])
        )

        {:ok, context}
      end

      then_ "the schema's parent is Feature", context do
        app = app(context)
        feature = component(context, "#{app}.Feature")
        item = component(context, "#{app}.Feature.Item")

        assert item["parent_component_id"] == feature["id"]
        {:ok, context}
      end
    end
  end
end
