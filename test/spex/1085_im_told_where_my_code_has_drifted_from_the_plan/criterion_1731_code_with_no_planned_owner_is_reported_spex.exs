defmodule CodeMySpecSpex.Story1085.Criterion1731Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1731 — Code with no planned owner is reported.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Code with no planned owner is reported", criterion: 1731 do
    scenario "a module exists with no matching planned component" do
      given_ "Sam's code has a Webhooks module", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          ExecutionContexts.write_file(context.execution_context, "lib/webhooks.ex", """
          defmodule #{app}.Webhooks do
            @moduledoc false
          end
          """)

        {:ok, context}
      end

      given_ "no planned component owns it", context do
        # given: already true — the prior step wrote a file directly, with
        # no `design!` call authoring a matching component.
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

      then_ "Sam is told Webhooks has no planned component", context do
        assert match?({:ok, _}, context.check_response),
               "expected architecture check to succeed, got: #{inspect(context.check_response)}"

        body = response_text(context.check_response)

        assert body =~ "Webhooks",
               "expected the unowned-code finding to name Webhooks, got:\n#{body}"

        {:ok, context}
      end
    end
  end
end
