defmodule CodeMySpecSpex.Story127.Criterion1625Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1625 — Components and dependencies derived from spec files are still reconciled to the files.

  Leaving authored records alone must not stop specs driving the records
  they produced (3aeb66cf).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Components and dependencies derived from spec files are still reconciled to the files",
    criterion: 1625 do
    scenario "a spec drops a dependency, and another spec goes" do
      given_ "specs where Web depends on Accounts, synced", context do
        app = app(context)
        spec!(context, "#{app}.Web", ["#{app}.Accounts"])
        spec!(context, "#{app}.Accounts")
        spec!(context, "#{app}.Legacy")
        sync!(context)

        assert architecture(context) =~ edge(context, "Web", "Accounts")
        assert listed(context) =~ "#{app}.Legacy"
        {:ok, context}
      end

      when_ "Web's spec stops listing it, Legacy's spec is removed, and a full sync runs",
            context do
        app = app(context)
        spec!(context, "#{app}.Web")
        remove_spec!(context, "#{app}.Legacy")
        sync!(context)
        {:ok, context}
      end

      then_ "the dependency and the component follow the files", context do
        refute architecture(context) =~ edge(context, "Web", "Accounts")
        refute listed(context) =~ "#{app(context)}.Legacy"
        {:ok, context}
      end
    end
  end
end
