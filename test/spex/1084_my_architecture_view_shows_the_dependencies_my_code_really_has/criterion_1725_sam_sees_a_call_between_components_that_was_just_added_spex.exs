defmodule CodeMySpecSpex.Story1084.Criterion1725Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 1725 — Sam sees a call between components that was just added.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpec.ExecutionContexts

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam sees a call between components that was just added", criterion: 1725 do
    scenario "the architecture view shows the new in-code dependency" do
      given_ "Billing and Accounts are both designed contexts, and Billing's code now calls Accounts",
             context do
        design!(context, "Billing")
        design!(context, "Accounts")

        :ok =
          ExecutionContexts.write_file(context.execution_context, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
            alias Accounts

            def charge(order), do: Accounts.fetch(order)
          end
          """)

        sync!(context)
        {:ok, context}
      end

      when_ "Sam reads Billing's record", context do
        {:ok, Map.put(context, :deps, dependencies(context, "Billing"))}
      end

      then_ "it shows Billing depends on Accounts in the code", context do
        assert %{"in_code" => true} = context.deps["Accounts"],
               "expected Accounts as a code dependency of Billing: #{inspect(context.deps)}"

        {:ok, context}
      end
    end
  end
end
