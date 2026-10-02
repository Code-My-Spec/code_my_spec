defmodule CodeMySpecSpex.Story70.Criterion1645Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1645 — The orphan message names the tools that resolve an orphan: set_story_component, add_dependency from a story-linked context, update_component to infrastructure, or delete_component.

  Components as records, step 5 (3aeb66cf): `architecture_designed` reads the
  component records — authored, discovered or unmarked — instead of a proposal
  file and spec edits. Observed through `show_requirement`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The orphan message names the tools that resolve an orphan: set_story_component, add_dependency from a story-linked context, update_component to infrastructure, or delete_component",
    criterion: 1645 do
    scenario "an authored context no story covers" do
      given_ "a project with an authored Billing context no story covers", context do
        ComponentHelpers.create(context.scope,
          name: "Billing",
          module_name: "#{app(context)}.Billing",
          type: "context"
        )

        {:ok, context}
      end

      when_ "architecture is checked", context do
        {:ok, Map.put(context, :verdict, architecture_designed(context))}
      end

      then_ "the message names each resolving tool", context do
        for tool <- ~w(set_story_component add_dependency update_component delete_component),
            do: assert(context.verdict =~ tool, "the orphan message does not name " <> tool)

        refute context.verdict =~ "## Dependencies"
        {:ok, context}
      end
    end
  end
end
