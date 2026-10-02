defmodule CodeMySpecSpex.Story70.Criterion1641Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1641 — Architecture counts as designed without a proposal file once the project has an authored component, and a proposal file still counts as before.

  Components as records, step 5 (3aeb66cf): `architecture_designed` reads the
  component records — authored, discovered or unmarked — instead of a proposal
  file and spec edits. Observed through `show_requirement`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Architecture counts as designed without a proposal file once the project has an authored component, and a proposal file still counts as before",
    criterion: 1641 do
    scenario "the architect authors a component and writes no proposal" do
      when_ "the architect, finding no architecture yet, creates a component with the tools",
            context do
        assert architecture_designed(context) =~ "No architecture yet"

        ComponentHelpers.create(context.scope,
          name: "Accounts",
          module_name: "#{app(context)}.Accounts",
          type: "module"
        )

        {:ok, context}
      end

      then_ "architecture counts as designed, with no proposal file", context do
        refute architecture_designed(context) =~ "No architecture yet"
        assert architecture_designed(context) =~ "**Status:** Satisfied"
        {:ok, context}
      end
    end
  end
end
