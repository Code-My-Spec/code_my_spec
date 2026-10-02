defmodule CodeMySpecSpex.Story70.Criterion1619Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1619 — Executing a proposal creates its components and their dependencies as records, with no spec file written.

  Components as records, step 2 (3aeb66cf): executing a proposal writes the graph as
  records — components, parents and dependencies — and no spec file.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Executing a proposal creates its components and their dependencies as records, with no spec file written",
    criterion: 1619 do
    scenario "a proposal with a surface component and two contexts" do
      given_ "a story for the surface component to carry", context do
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

      when_ "the architect executes a proposal declaring them and their dependencies", context do
        execute_proposal!(
          context,
          proposal(context, context.story.number, [{"Feature", []}, {"Billing", []}], [
            {"FeatureLive", "Feature"},
            {"Feature", "Billing"}
          ])
        )

        {:ok, context}
      end

      then_ "the components and their dependencies are recorded", context do
        app = app(context)

        for module <- ["#{app}Web.FeatureLive", "#{app}.Feature", "#{app}.Billing"],
            do: assert(listed(context) =~ module, "#{module} was not recorded")

        assert architecture(context) =~ edge(context, "FeatureLive", "Feature")
        assert architecture(context) =~ edge(context, "Feature", "Billing")
        {:ok, context}
      end

      then_ "no spec file is written", context do
        app = app(context)

        for module <- ["#{app}Web.FeatureLive", "#{app}.Feature", "#{app}.Billing"],
            do: refute(spec_written?(context, module), "a spec was written for #{module}")

        {:ok, context}
      end
    end
  end
end
