defmodule CodeMySpecSpex.Story1085.Criterion1729Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1729 — An unplanned dependency is reported.

  Sam planned Billing to depend only on Accounts, but the code also
  calls Notifications from Billing. Checking the architecture reports
  the Billing -> Notifications edge as drift: present in the code,
  never planned.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unplanned dependency is reported", criterion: 1729 do
    scenario "the code calls a module that was never a planned dependency" do
      given_ "Sam planned Billing to depend only on Accounts", context do
        app = ComponentGraphHelpers.app(context)

        ComponentGraphHelpers.design!(context, "#{app}.Accounts")
        ComponentGraphHelpers.design!(context, "#{app}.Notifications")
        billing = ComponentGraphHelpers.design!(context, "#{app}.Billing", ["#{app}.Accounts"])

        {:ok, Map.put(context, :billing, billing)}
      end

      given_ "the code also calls Notifications from Billing", context do
        app = ComponentGraphHelpers.app(context)

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

        response =
          ToolLibrary.run(
            "check_architecture",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :check_response, response)}
      end

      then_ "Sam is told Billing depends on Notifications without it being planned", context do
        assert match?({:ok, _}, context.check_response),
               "expected architecture check to succeed, got: #{inspect(context.check_response)}"

        body = response_text(context.check_response)

        assert body =~ "Billing",
               "expected the unplanned dependency to name Billing, got:\n#{body}"

        assert body =~ "Notifications",
               "expected the unplanned dependency to name Notifications, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
