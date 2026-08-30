defmodule CodeMySpecSpex.Story1039.Criterion3007Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3007 — An account with only one provider still gets a sensible model

  A fresh account has connected one thing and set nothing. It should still run
  every type — which is the measure of whether the defaults are actually sane
  rather than a placeholder.
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
    scenario "An account with only one provider still gets a sensible model" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "the account has a key for one provider only", context do
        Fixtures.connect_provider(context.scope, "zai")
        {:ok, context}
      end

      given_ "nobody has configured the QA type", context do
        # given: already true — nothing has been set, and this is the state a
        # new account is in. Named rather than assumed because the criterion is
        # about the unset case specifically.
        {:ok, context}
      end

      when_ "a QA agent is started", context do
        {:reply, response, _} = StartAgent.execute(%{role: "qa"}, context.frame)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "it starts", context do
        refute context.response.isError
        {:ok, context}
      end

      then_ "on the provider the account actually has", context do
        assert response_text(context.response) =~ "zai"
        {:ok, context}
      end
    end
  end
end
