defmodule CodeMySpecSpex.Story1039.Criterion3013Spex do
  @moduledoc """
  Story 1039 — I choose which model each agent runs on
  Criterion 3013 — A type that does not exist cannot be created by typing it

  `Agent.role` becomes an `Ecto.Enum` for this. As a plain `:string` a typo
  makes a phantom type: a row nothing launches, a setting nothing reads, and no
  error anywhere to say so.
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
    scenario "A type that does not exist cannot be created by typing it" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "a provider is connected", context do
        Fixtures.connect_provider(context.scope, "zai")
        {:ok, context}
      end

      when_ "something tries to start an agent as a type the code does not define", context do
        {:reply, response, _} = StartAgent.execute(%{role: "quality_assurance"}, context.frame)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is refused", context do
        assert context.response.isError
        {:ok, context}
      end

      then_ "and the refusal names the types there are", context do
        text = response_text(context.response)

        assert text =~ "qa",
               "a refusal that does not say what the types are leaves the caller guessing " <>
                 "at the spelling of something it cannot see"

        {:ok, context}
      end
    end
  end
end
