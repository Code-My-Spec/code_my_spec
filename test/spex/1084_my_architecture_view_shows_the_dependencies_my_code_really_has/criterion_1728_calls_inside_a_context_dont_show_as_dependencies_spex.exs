defmodule CodeMySpecSpex.Story1084.Criterion1728Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 1728 — Calls inside a context don't show as dependencies.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Calls inside a context don't show as dependencies", criterion: 1728 do
    scenario "an intra-context call is hidden while a cross-context call is shown" do
      given_ "Billing's code calls its own Invoice module, and also calls Accounts", context do
        design!(context, "Billing")
        design!(context, "Billing.Invoice", [], parent: "Billing", type: "schema")
        design!(context, "Accounts")

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
            alias Billing.Invoice
            alias Accounts

            def charge(order) do
              Invoice.new(order)
              Accounts.fetch(order)
            end
          end
          """)

        sync!(context)
        {:ok, context}
      end

      when_ "Sam reads Billing's record", context do
        {:ok, Map.put(context, :deps, dependencies(context, "Billing"))}
      end

      then_ "no dependency is shown for the call to Billing's own Invoice module", context do
        refute Map.has_key?(context.deps, "Billing.Invoice"),
               "expected the intra-context call to Invoice to be hidden: #{inspect(context.deps)}"

        {:ok, context}
      end

      then_ "a call from Billing to Accounts is shown", context do
        assert Map.has_key?(context.deps, "Accounts"),
               "expected the cross-context call to Accounts to be shown: #{inspect(context.deps)}"

        {:ok, context}
      end
    end
  end
end
