defmodule CodeMySpecSpex.Story1039.Criterion3010Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3010 — A running agent keeps the model it started on

  Changing a setting decides what happens next. It is not a way to move an
  agent mid-turn onto a model it did not start with — an agent whose provider
  changed underneath it is one whose transcript stops making sense.
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
    scenario "A running agent keeps the model it started on" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "both providers are connected", context do
        Fixtures.connect_provider(context.scope, "zai")
        Fixtures.connect_provider(context.scope, "anthropic")
        {:ok, context}
      end

      given_ "a coding agent is running", context do
        :ok = set_model(context, "coding", "zai", "glm-first")
        {:reply, response, _} = StartAgent.execute(%{role: "coding"}, context.frame)
        refute response.isError

        {:ok, Map.put(context, :first, response)}
      end

      when_ "the coding type is pointed at a different model", context do
        :ok = set_model(context, "coding", "anthropic", "claude-second")
        {:ok, context}
      end

      then_ "the running agent is still on the one it started with", context do
        assert response_text(context.first) =~ "glm-first"
        {:ok, context}
      end

      then_ "and the next coding agent started uses the new one", context do
        {:reply, response, _} = StartAgent.execute(%{role: "coding"}, context.frame)
        assert response_text(response) =~ "claude-second"
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
