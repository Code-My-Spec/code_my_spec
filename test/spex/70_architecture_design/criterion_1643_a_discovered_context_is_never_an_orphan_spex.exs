defmodule CodeMySpecSpex.Story70.Criterion1643Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1643 — A discovered context is never an orphan.

  Components as records, step 5 (3aeb66cf): `architecture_designed` reads the
  component records — authored, discovered or unmarked — instead of a proposal
  file and spec edits. Observed through `show_requirement`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A discovered context is never an orphan", criterion: 1643 do
    scenario "code nobody specified turns out to be a context" do
      given_ "a frozen project whose architecture is authored", context do
        ComponentHelpers.create(context.scope,
          name: "Accounts",
          module_name: "#{app(context)}.Accounts",
          type: "module"
        )

        freeze(context, write: true)
        {:ok, context}
      end

      given_ "code for Helper, synced as discovered and typed as a context", context do
        implementation!(context, "#{app(context)}.Helper")
        sync!(context)
        retype!(context, "#{app(context)}.Helper", "context")
        {:ok, context}
      end

      when_ "architecture is checked", context do
        {:ok, Map.put(context, :verdict, architecture_designed(context))}
      end

      then_ "Helper is not an orphan", context do
        refute context.verdict =~ "#{app(context)}.Helper"
        assert context.verdict =~ "**Status:** Satisfied"
        {:ok, context}
      end
    end
  end
end
