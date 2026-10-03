defmodule CodeMySpecSpex.Story1085.Criterion1730Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1730 — A planned component with no code is reported.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Architecture.Tools.CheckArchitecture
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A planned component with no code is reported", criterion: 1730 do
    scenario "a designed context has never been written" do
      given_ "Sam planned a Reports context", context do
        app = ComponentGraphHelpers.app(context)
        reports = ComponentGraphHelpers.design!(context, "#{app}.Reports")

        {:ok, Map.put(context, :reports, reports)}
      end

      given_ "no Reports module exists in the code", context do
        {:ok, context}
      end

      when_ "architecture is checked", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckArchitecture.execute(%{}, frame)

        {:ok, Map.put(context, :check_response, response)}
      end

      then_ "Sam is told Reports is planned but has no code", context do
        refute context.check_response.isError,
               "expected architecture check to succeed, got: #{inspect(context.check_response)}"

        body = response_text(context.check_response)

        assert body =~ "Reports",
               "expected the missing-code finding to name Reports, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
