defmodule CodeMySpecSpex.Story1084.Criterion2092Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 2092 — Only actual source uses create code dependencies.

  An alias and a module attribute name a component without using it. A remote
  call creates the observed dependency after the project syncs.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Only actual source uses create code dependencies", criterion: 2092 do
    scenario "an alias alone is ignored, then a remote call is recorded" do
      given_ "Billing and Accounts are designed, and Billing only names Accounts", context do
        app = ComponentGraphHelpers.app(context)
        ComponentGraphHelpers.design!(context, "#{app}.Billing")
        ComponentGraphHelpers.design!(context, "#{app}.Accounts")

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
              @account_module Accounts
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "alias and config evidence do not create a dependency", context do
        deps = billing_deps(context)

        refute Map.has_key?(deps, "Accounts"),
               "expected no Accounts dependency from alias/config alone: #{inspect(deps)}"

        {:ok, context}
      end

      when_ "Billing makes a remote call and the project syncs", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts

              def charge(order), do: Accounts.fetch(order)
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "the call creates an observed code dependency", context do
        deps = billing_deps(context)

        assert %{"in_code" => true} = deps["Accounts"],
               "expected the call to mark Accounts as in code: #{inspect(deps)}"

        {:ok, context}
      end
    end
  end

  # get_component's dependencies for Billing, keyed relative to the app.
  defp billing_deps(context) do
    app = ComponentGraphHelpers.app(context)

    context
    |> ComponentGraphHelpers.dependencies("#{app}.Billing")
    |> Map.new(fn {module, evidence} ->
      {String.replace_prefix(module, app <> ".", ""), evidence}
    end)
  end
end
