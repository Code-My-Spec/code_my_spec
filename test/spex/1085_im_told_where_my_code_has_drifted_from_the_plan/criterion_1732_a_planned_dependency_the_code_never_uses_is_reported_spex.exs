defmodule CodeMySpecSpex.Story1085.Criterion1732Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1732 — A planned dependency the code never uses is reported.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A planned dependency the code never uses is reported", criterion: 1732 do
    scenario "a planned edge has no matching call in the code" do
      given_ "Sam planned Billing to depend on Accounts", context do
        app = ComponentGraphHelpers.app(context)

        ComponentGraphHelpers.design!(context, "#{app}.Accounts")
        billing = ComponentGraphHelpers.design!(context, "#{app}.Billing", ["#{app}.Accounts"])

        {:ok, Map.put(context, :billing, billing)}
      end

      given_ "Billing never calls Accounts", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(context.environment, "lib/billing.ex", """
          defmodule #{app}.Billing do
            @moduledoc false
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

      then_ "Sam is told the planned dependency from Billing to Accounts isn't in the code",
            context do
        assert match?({:ok, _}, context.check_response),
               "expected architecture check to succeed, got: #{inspect(context.check_response)}"

        body = response_text(context.check_response)

        assert body =~ "Billing",
               "expected the unused-dependency finding to name Billing, got:\n#{body}"

        assert body =~ "Accounts",
               "expected the unused-dependency finding to name Accounts, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
