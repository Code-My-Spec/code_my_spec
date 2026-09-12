defmodule CodeMySpecSpex.Story1039.Criterion3009Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3009 — A fresh account can run every type without visiting a settings page

  The measure of whether the defaults are sane: an account that connected one
  provider and touched nothing else can start all four types.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I choose which model each agent runs on" do
    scenario "A fresh account can run every type without visiting a settings page" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "an account that has connected one provider and set nothing else", context do
        Fixtures.connect_provider(context.scope, "zai")
        {:ok, context}
      end

      when_ "each agent type is started in turn", context do
        started =
          for role <- ["main", "product", "coding", "qa"] do
            {:reply, response, _} = StartAgent.execute(%{role: role}, context.frame)
            {role, response}
          end

        {:ok, Map.put(context, :started, started)}
      end

      then_ "all of them start", context do
        for {role, response} <- context.started do
          refute response.isError, "#{role} could not start: #{response_text(response)}"
        end

        {:ok, context}
      end
    end
  end
end
