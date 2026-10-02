defmodule CodeMySpecSpex.Story682.Criterion1622Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 1622 — Creating a component writes no spec file.

  `create_component` wrote a stub spec, which was the only way the
  component's dependencies could be recorded. They are records now (3aeb66cf).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Creating a component writes no spec file", criterion: 1622 do
    scenario "the architect adds one component" do
      when_ "the architect creates a component that has no spec", context do
        refute spec_written?(context, "#{app(context)}.Notifications")

        CodeMySpecSpex.ComponentHelpers.create(context.scope,
          name: "Notifications",
          module_name: "#{app(context)}.Notifications",
          type: "context"
        )

        {:ok, context}
      end

      then_ "it is recorded, and no spec file is written", context do
        assert listed(context) =~ "#{app(context)}.Notifications"
        refute spec_written?(context, "#{app(context)}.Notifications")
        {:ok, context}
      end
    end
  end
end
