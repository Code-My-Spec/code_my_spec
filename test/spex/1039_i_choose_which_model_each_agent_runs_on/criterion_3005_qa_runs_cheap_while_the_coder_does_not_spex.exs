defmodule CodeMySpecSpex.Story1039.Criterion3005Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3005 — QA runs cheap while the coder does not

  The whole point of the setting: two types, two models, one launcher.

  The models are set through the screen rather than seeded, because that is the
  only surface for it and driving it here is what proves the setting and the
  launcher meet.
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
    scenario "QA runs cheap while the coder does not" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "both providers are connected", context do
        Fixtures.connect_provider(context.scope, "zai")
        Fixtures.connect_provider(context.scope, "anthropic")
        {:ok, context}
      end

      given_ "QA is set to a cheap model and coding to an expensive one", context do
        {:ok, view, _html} = live(context.conn, "/app/accounts/#{context.account.id}/agents")

        view
        |> form("[data-test='agent-models-form']", %{
          "qa" => %{"provider" => "zai", "model" => "glm-cheap"},
          "coding" => %{"provider" => "anthropic", "model" => "claude-expensive"}
        })
        |> render_submit()

        {:ok, context}
      end

      when_ "one of each is started", context do
        {:reply, qa, _} = StartAgent.execute(%{role: "qa"}, context.frame)
        {:reply, coding, _} = StartAgent.execute(%{role: "coding"}, context.frame)

        {:ok, context |> Map.put(:qa, qa) |> Map.put(:coding, coding)}
      end

      then_ "each is running on the model its type was given", context do
        assert response_text(context.qa) =~ "glm-cheap"
        assert response_text(context.coding) =~ "claude-expensive"
        {:ok, context}
      end
    end
  end

end
