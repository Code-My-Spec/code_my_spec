defmodule CodeMySpecSpex.Story1084.Criterion1726Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 1726 — A call removed from the code is gone from the view.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A call removed from the code is gone from the view", criterion: 1726 do
    scenario "the architecture view stops showing a deleted in-code dependency" do
      given_ "Billing's code used to call Accounts, and that call was deleted", context do
        design!(context, "Billing")
        design!(context, "Accounts")

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
            alias Accounts

            def charge(order), do: Accounts.fetch(order)
          end
          """)

        sync!(context)

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
          end
          """)

        sync!(context)
        {:ok, context}
      end

      when_ "Sam reads Billing's record", context do
        {:ok, Map.put(context, :deps, dependencies(context, "Billing"))}
      end

      then_ "no code dependency from Billing to Accounts is shown", context do
        refute Map.has_key?(context.deps, "Accounts"),
               "expected no Accounts dependency after the code call was removed: #{inspect(context.deps)}"

        {:ok, context}
      end
    end
  end
end
