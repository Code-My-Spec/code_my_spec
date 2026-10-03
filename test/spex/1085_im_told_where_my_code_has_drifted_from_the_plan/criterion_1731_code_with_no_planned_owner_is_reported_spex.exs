defmodule CodeMySpecSpex.Story1085.Criterion1731Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1731 — Code with no planned owner is reported.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.Tools.CheckArchitecture
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Code with no planned owner is reported", criterion: 1731 do
    scenario "a module exists with no matching planned component" do
      given_ "Sam's code has a Webhooks module", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(context.environment, "lib/webhooks.ex", """
          defmodule #{app}.Webhooks do
            @moduledoc false
          end
          """)

        {:ok, context}
      end

      given_ "no planned component owns it", context do
        {:ok, context}
      end

      when_ "architecture is checked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckArchitecture.execute(%{}, frame)

        {:ok, Map.put(context, :check_response, response)}
      end

      then_ "Sam is told Webhooks has no planned component", context do
        refute context.check_response.isError,
               "expected architecture check to succeed, got: #{inspect(context.check_response)}"

        body = response_text(context.check_response)

        assert body =~ "Webhooks",
               "expected the unowned-code finding to name Webhooks, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
