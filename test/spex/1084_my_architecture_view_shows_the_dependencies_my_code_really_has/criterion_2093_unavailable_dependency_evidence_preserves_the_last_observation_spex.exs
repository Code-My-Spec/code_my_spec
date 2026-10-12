defmodule CodeMySpecSpex.Story1084.Criterion2093Spex do
  @moduledoc """
  Story 1084 — My architecture view shows the dependencies my code really has
  Criterion 2093 — Unavailable dependency evidence preserves the last observation.

  A source parse failure cannot prove an observed dependency disappeared. Once
  valid source is available again, the observation is refreshed while authored
  intent remains recorded.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unavailable dependency evidence preserves the last observation", criterion: 2093 do
    scenario "a syntax error preserves observed edges until valid source returns" do
      given_ "Billing has an authored Accounts edge and code uses Accounts and Notifications",
             context do
        app = ComponentGraphHelpers.app(context)
        billing = ComponentGraphHelpers.design!(context, "#{app}.Billing")
        accounts = ComponentGraphHelpers.design!(context, "#{app}.Accounts")
        ComponentGraphHelpers.design!(context, "#{app}.Notifications")
        ComponentGraphHelpers.depend!(context, billing, accounts)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
              alias #{app}.Notifications

              def charge(order) do
                Accounts.fetch(order)
                Notifications.notify(order)
              end
            end
            """
          )

        ComponentGraphHelpers.sync!(context)

        {:ok, context}
      end

      when_ "the source has a syntax error and sync runs", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
              alias #{app}.Notifications

              def charge(order do
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "the last authored and observed evidence is retained", context do
        deps = billing_deps(context)

        assert deps["Accounts"] == %{"planned" => true, "in_code" => true},
               "expected Accounts to remain planned, with its last observation: #{inspect(deps)}"

        assert %{"in_code" => true} = deps["Notifications"],
               "expected Notifications to remain marked in code: #{inspect(deps)}"

        {:ok, context}
      end

      when_ "valid source returns without either remote call and sync runs", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/#{Macro.underscore("#{app}.Billing")}.ex",
            """
            defmodule #{app}.Billing do
              @moduledoc false
              alias #{app}.Accounts
            end
            """
          )

        ComponentGraphHelpers.sync!(context)
        {:ok, context}
      end

      then_ "the observed-only edge clears while the authored plan remains", context do
        deps = billing_deps(context)

        assert deps["Accounts"] == %{"planned" => true, "in_code" => false},
               "expected Accounts to remain planned, its code marker cleared: #{inspect(deps)}"

        refute Map.has_key?(deps, "Notifications"),
               "expected the observed-only Notifications edge to disappear: #{inspect(deps)}"

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
