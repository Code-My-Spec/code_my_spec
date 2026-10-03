defmodule CodeMySpecSpex.Story1085.Criterion1735Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1735 — Off reports nothing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.Tools.CheckArchitecture
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Off reports nothing", criterion: 1735 do
    scenario "architecture checking is turned off entirely" do
      given_ :on_configuration_page

      given_ "Sam set architecture to off", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{architecture: "off"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the code has an unplanned dependency", context do
        app = ComponentGraphHelpers.app(context)

        ComponentGraphHelpers.design!(context, "#{app}.Accounts")
        ComponentGraphHelpers.design!(context, "#{app}.Notifications")
        ComponentGraphHelpers.design!(context, "#{app}.Billing", ["#{app}.Accounts"])

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule #{app}.Billing do
            @moduledoc false
            alias #{app}.Notifications

            def charge(order), do: Notifications.notify(order)
          end
          """)

        {:ok, context}
      end

      given_ "the project is synced so the checker sees the code", context do
        ComponentGraphHelpers.sync!(context)

        {:ok, context}
      end

      when_ "architecture is checked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckArchitecture.execute(%{}, frame)

        {:ok, Map.put(context, :check_response, response)}
      end

      then_ "no drift is reported", context do
        refute context.check_response.isError,
               "expected architecture check to succeed even when off, got: #{inspect(context.check_response)}"

        body = response_text(context.check_response)

        assert body != "",
               "expected a non-empty response confirming the check ran even while off"

        refute body =~ "Notifications",
               "expected no drift findings while architecture is off, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
