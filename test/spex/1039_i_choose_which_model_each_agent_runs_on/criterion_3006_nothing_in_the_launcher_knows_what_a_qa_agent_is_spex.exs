defmodule CodeMySpecSpex.Story1039.Criterion3006Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3006 — Nothing in the launcher knows what a QA agent is

  The setting is the only thing that differs between two starts. If the
  launcher branched on the type instead, changing the setting would not change
  where the agent goes — which is the hardcoding this story exists to remove.

  So the second `then_` swaps the setting and starts the same type again. One
  start proves nothing; the change is the assertion.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I choose which model each agent runs on" do
    scenario "Nothing in the launcher knows what a QA agent is" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "both providers are connected", context do
        Fixtures.connect_provider(context.scope, "zai")
        Fixtures.connect_provider(context.scope, "anthropic")
        {:ok, context}
      end

      given_ "two types are set to different providers", context do
        {:ok, view, _html} = live(context.conn, "/app/accounts/#{context.account.id}/agents")

        view
        |> form("[data-test='agent-models-form']", %{
          "qa" => %{"provider" => "zai", "model" => "glm-cheap"},
          "product" => %{"provider" => "anthropic", "model" => "claude-expensive"}
        })
        |> render_submit()

        {:ok, context}
      end

      when_ "each is started through the same path", context do
        {:reply, qa, _} = StartAgent.execute(%{role: "qa"}, context.frame)
        {:reply, product, _} = StartAgent.execute(%{role: "product"}, context.frame)

        {:ok, context |> Map.put(:qa, qa) |> Map.put(:product, product)}
      end

      then_ "each reaches its own provider", context do
        assert response_text(context.qa) =~ "zai"
        assert response_text(context.product) =~ "anthropic"
        {:ok, context}
      end

      then_ "and pointing QA elsewhere moves it", context do
        :ok = set_model(context, "qa", "anthropic", "claude-expensive")

        {:reply, qa, _} = StartAgent.execute(%{role: "qa"}, context.frame)

        assert response_text(qa) =~ "anthropic",
               "the launcher decided by type rather than by setting"

        {:ok, context}
      end
    end
  end

  defp set_model(context, type, provider, model) do
    {:ok, view, _html} = live(context.conn, "/app/accounts/#{context.account.id}/agents")

    view
    |> form("[data-test='agent-models-form']", %{
      type => %{"provider" => provider, "model" => model}
    })
    |> render_submit()

    :ok
  end
end
