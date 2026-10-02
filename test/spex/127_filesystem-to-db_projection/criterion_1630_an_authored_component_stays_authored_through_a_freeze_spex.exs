defmodule CodeMySpecSpex.Story127.Criterion1630Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1630 — A component already marked authored stays authored through a freeze.

  Components as records, step 3 (3aeb66cf): the one-time freeze that writes
  what each component is for into its record. Surface: `freeze_components`,
  observed through its report and `get_component`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A component already marked authored stays authored through a freeze", criterion: 1630 do
    scenario "an agent created a component no spec names" do
      given_ "Web and Accounts have specs, Web depending on Accounts, and Helper only code",
             context do
        app = app(context)
        spec!(context, "#{app}.Web", ["#{app}.Accounts"])
        spec!(context, "#{app}.Accounts")
        implementation!(context, "#{app}.Helper")
        sync!(context)
        {:ok, context}
      end

      given_ "an agent creates Billing", context do
        CodeMySpecSpex.ComponentHelpers.create(context.scope,
          name: "Billing",
          module_name: "#{app(context)}.Billing",
          type: "context"
        )

        {:ok, context}
      end

      when_ "the freeze runs", context do
        freeze(context, write: true)
        {:ok, context}
      end

      then_ "Billing is still authored", context do
        assert component(context, "#{app(context)}.Billing")["provenance"] == "authored"
        {:ok, context}
      end
    end
  end
end
