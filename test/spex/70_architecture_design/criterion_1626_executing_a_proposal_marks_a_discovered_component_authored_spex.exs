defmodule CodeMySpecSpex.Story70.Criterion1626Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1626 — Executing a proposal marks a matching discovered component as authored.

  Decision 1 of 3aeb66cf: components discovered from code are kept and
  flagged, and authoring one makes it authored.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Executing a proposal marks a matching discovered component as authored",
    criterion: 1626 do
    scenario "code was written before the architecture named it" do
      given_ "a component discovered from an implementation file", context do
        implementation!(context, "#{app(context)}.Feature")
        sync!(context)

        refute component(context, "#{app(context)}.Feature")["provenance"] == "authored"

        {:ok,
         Map.put(
           context,
           :story,
           StoryHelpers.create_story(context.scope,
             title: "A feature",
             description: "Needs a feature",
             acceptance_criteria: ["It works"]
           )
         )}
      end

      when_ "the architect executes a proposal naming it", context do
        execute_proposal!(
          context,
          proposal(context, context.story.number, [{"Feature", []}], [{"FeatureLive", "Feature"}])
        )

        {:ok, context}
      end

      then_ "it is authored", context do
        assert component(context, "#{app(context)}.Feature")["provenance"] == "authored"
        {:ok, context}
      end
    end
  end
end
