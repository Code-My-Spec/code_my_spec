defmodule CodeMySpecSpex.Story127.Criterion1623Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1623 — A dependency an agent added survives a full sync even when the component's spec does not list it.

  A full sync took a spec's `## Dependencies` as the whole truth and
  deleted every other edge, undoing `add_dependency` (3aeb66cf).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A dependency an agent added survives a full sync even when the component's spec does not list it",
    criterion: 1623 do
    scenario "the spec declares no dependencies" do
      given_ "two designed contexts, with specs that declare no dependencies", context do
        app = app(context)
        design!(context, "#{app}.Web")
        design!(context, "#{app}.Accounts")
        spec!(context, "#{app}.Web")
        spec!(context, "#{app}.Accounts")
        {:ok, context}
      end

      given_ "an agent adds a dependency between them", context do
        app = app(context)
        web = CodeMySpecSpex.Fixtures.get_component_by_module_name(context.scope, "#{app}.Web")

        accounts =
          CodeMySpecSpex.Fixtures.get_component_by_module_name(context.scope, "#{app}.Accounts")

        depend!(context, web, accounts)
        assert architecture(context) =~ edge(context, "Web", "Accounts")
        {:ok, context}
      end

      when_ "a full sync runs", context do
        sync!(context)
        {:ok, context}
      end

      then_ "the dependency is still there", context do
        assert architecture(context) =~ edge(context, "Web", "Accounts")
        {:ok, context}
      end
    end
  end
end
