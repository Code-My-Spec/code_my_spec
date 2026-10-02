defmodule CodeMySpecSpex.Story70.Criterion1642Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1642 — An authored context that no story covers, directly, through a descendant or as a dependency of a covered one, is an orphan whether or not its code exists yet.

  Components as records, step 5 (3aeb66cf): `architecture_designed` reads the
  component records — authored, discovered or unmarked — instead of a proposal
  file and spec edits. Observed through `show_requirement`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An authored context that no story covers, directly, through a descendant or as a dependency of a covered one, is an orphan whether or not its code exists yet",
    criterion: 1642 do
    scenario "a context designed ahead of its code" do
      given_ "a project whose architecture is authored", context do
        ComponentHelpers.create(context.scope,
          name: "Accounts",
          module_name: "#{app(context)}.Accounts",
          type: "module"
        )

        {:ok, context}
      end

      when_ "the architect creates a Billing context that no story covers, with no code",
            context do
        ComponentHelpers.create(context.scope,
          name: "Billing",
          module_name: "#{app(context)}.Billing",
          type: "context"
        )

        {:ok, context}
      end

      then_ "Billing is an orphan", context do
        assert architecture_designed(context) =~ "orphan"
        assert architecture_designed(context) =~ "#{app(context)}.Billing"
        {:ok, context}
      end
    end
  end
end
