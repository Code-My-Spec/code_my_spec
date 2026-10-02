defmodule CodeMySpecSpex.Story70.Criterion1644Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1644 — A context with no provenance is an orphan only where this checkout has its files, as before.

  Components as records, step 5 (3aeb66cf): `architecture_designed` reads the
  component records — authored, discovered or unmarked — instead of a proposal
  file and spec edits. Observed through `show_requirement`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A context with no provenance is an orphan only where this checkout has its files, as before",
    criterion: 1644 do
    scenario "a project never frozen syncs a context from its spec" do
      given_ "a project whose architecture is authored", context do
        ComponentHelpers.create(context.scope,
          name: "Accounts",
          module_name: "#{app(context)}.Accounts",
          type: "module"
        )

        {:ok, context}
      end

      when_ "a spec for Legacy is synced, giving an unmarked context with its file here",
            context do
        spec!(context, "#{app(context)}.Legacy")
        sync!(context)
        {:ok, context}
      end

      then_ "Legacy is an orphan", context do
        assert architecture_designed(context) =~ "#{app(context)}.Legacy"
        {:ok, context}
      end
    end
  end
end
