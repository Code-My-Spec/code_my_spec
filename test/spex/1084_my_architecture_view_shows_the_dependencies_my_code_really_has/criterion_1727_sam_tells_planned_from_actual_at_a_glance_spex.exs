defmodule CodeMySpecSpex.Story1084.Criterion1727Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 1727 — Sam tells planned from actual at a glance.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam tells planned from actual at a glance", criterion: 1727 do
    scenario "a planned-and-coded dependency reads differently from a code-only one" do
      given_ "Sam planned Billing depending on Accounts, and the code also calls Notifications from Billing",
             context do
        billing = design!(context, "Billing")
        accounts = design!(context, "Accounts")
        design!(context, "Notifications")

        depend!(context, billing, accounts)

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule Billing do
            @moduledoc false
            alias Accounts
            alias Notifications

            def charge(order) do
              Accounts.fetch(order)
              Notifications.notify(order)
            end
          end
          """)

        sync!(context)
        {:ok, context}
      end

      when_ "Sam reads Billing's record", context do
        {:ok, Map.put(context, :deps, dependencies(context, "Billing"))}
      end

      then_ "Billing to Accounts is marked planned and in code", context do
        assert context.deps["Accounts"] == %{"planned" => true, "in_code" => true},
               "expected Accounts planned and in code: #{inspect(context.deps)}"

        {:ok, context}
      end

      then_ "Billing to Notifications is marked in code only", context do
        assert context.deps["Notifications"] == %{"planned" => false, "in_code" => true},
               "expected Notifications in code only: #{inspect(context.deps)}"

        {:ok, context}
      end
    end
  end
end
