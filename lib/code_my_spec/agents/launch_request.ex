defmodule CodeMySpec.Agents.LaunchRequest do
  @moduledoc """
  What the server sends a machine to bring one agent up.

  The one definition, used for a fresh start and a restore alike, so a field
  added for one reaches the other.

  What travels: what to run and where, the credential, the conversation so far
  (an agent dies with its harness; the transcript is its state), and the
  prompt sections. Not a command: the machine knows what is installed on it.

  Credential and history ride on the agent as virtual fields, resolved by
  `hydrate/2`; neither is stored on the row.

  See knowledge/agents/coordination, "Launch requests".
  """

  alias CodeMySpec.Agents.{
    Agent,
    Credential,
    Defaults,
    OperatingRules,
    ProviderBrief,
    RoleBrief,
    ToolIndex
  }

  alias CodeMySpec.Conversations
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @doc """
  Fill in the two things a launch needs and the row does not hold.

  Called wherever an agent is about to be sent to a machine — a start, and a
  restore after that machine came back. Skipping it sends an agent with no
  credential and no memory.
  """
  @spec hydrate(Scope.t(), Agent.t()) :: Agent.t()
  def hydrate(%Scope{} = scope, %Agent{} = agent) do
    %{
      agent
      | credential: agent.credential || credential(scope, agent),
        history: history(scope, agent)
    }
  end

  @doc """
  The wire map for this agent.

  Reads the virtual fields rather than resolving anything, so what is sent is
  what the caller decided to send. An unhydrated agent produces a request with
  no credential and no history — a first start, which is exactly what it looks
  like.

  `tools` is `McpServers.ToolRegistry.registry/0`, handed in because `Agents`
  sits below the servers it would otherwise read. See the `ToolIndex.registry` type.
  """
  @spec for(Agent.t(), ToolIndex.registry()) :: map()
  def for(%Agent{} = agent, tools) do
    %{
      "agent_id" => agent.id,
      "engine" => to_string(agent.engine),
      "provider" => agent.provider,
      # The agent's model, else its role's for this provider; nil leaves the
      # choice to the provider.
      "model" => model(agent),
      "working_copy" => agent.working_copy,
      "role" => agent.role,
      # What this agent is for, in words. Resolved here: role semantics are the
      # framework's, not the harness's.
      "role_brief" => RoleBrief.for(agent.role),
      # Section one: the loop every agent runs and how the machinery behaves;
      # the same for every role and project. See `OperatingRules`.
      "universal" => OperatingRules.text(),
      # Section two, first part: what this project is. Nil when unwritten,
      # never a placeholder.
      "project_brief" => project_brief(agent),
      # Every tool it can reach, by name only. See `Agents.ToolIndex`.
      "tool_index" => ToolIndex.for(agent, tools, machine_tools(agent)),
      # The same grant as data, so the harness can say why a direct call missed.
      "tool_reach" => ToolIndex.reach(agent, tools),
      # The tools the engine carries directly, as the server registers them.
      # The harness builds its tools from these rather than keeping copies.
      "direct_tools" => ToolIndex.carried_definitions(tools),
      # How a tool call physically happens on this provider. See `ProviderBrief`.
      "provider_brief" => ProviderBrief.for(agent.provider),
      # Where the application is running: the main checkout's preview, whichever
      # copy the agent is in (only the main copy records one).
      "app_url" => app_url(agent),
      # Whether this agent is willing to be given new work, so a restore does
      # not bring a paused agent back working.
      "continuous" => agent.continuous == true,
      "messages" => demo_turns() ++ (agent.history || [])
    }
    |> Map.merge(credential_fields(agent.credential))
  end

  # Nil when nothing is serving the main checkout: "no address" is a fact an
  # agent can act on; a dead URL costs it a turn.
  defp app_url(%Agent{project_id: project_id}) when is_binary(project_id) do
    WorkingCopies.preview_url(%Scope{active_project_id: project_id})
  end

  defp app_url(_agent), do: nil

  # What the project is, in its own words; sent when written, omitted when not.
  # Keeping it true is the project's job.
  defp project_brief(%Agent{project_id: project_id}) when is_binary(project_id) do
    case Projects.get_project_by_id(project_id) do
      %{description: description} -> presence(description)
      nil -> nil
    end
  end

  defp project_brief(_agent), do: nil

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # The browser tools this machine offers, from the agent's copy. `[]` renders
  # as no section; a browser that will not answer is `browser_status`'s fault.
  defp machine_tools(%Agent{working_copy_id: id}) when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{machine_tools: tools}} when is_list(tools) -> tools
      _ -> []
    end
  end

  defp machine_tools(_agent), do: []

  # Where the agent picks up (`Conversations.resume_messages/1`). No
  # conversation is an empty history: a first start.
  defp history(%Scope{} = scope, %Agent{} = agent) do
    case Conversations.find_or_create_agent_conversation(
           scope.active_account_id,
           agent.project_id || scope.active_project_id,
           agent.id
         ) do
      {:ok, conversation} -> Conversations.resume_messages(conversation)
      _error -> []
    end
  end

  # Two calls the agent has already made: `health` direct and `script_health`
  # through `run_script`. Demonstration of the call shape rather than prose.
  # See knowledge/agents/coordination, "Launch requests".
  defp demo_turns do
    [
      %{
        "role" => "assistant",
        "content" => [
          %{"type" => "tool_use", "id" => "health-1", "name" => "health", "input" => %{}}
        ]
      },
      %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "health-1", "content" => "ok"}
        ]
      },
      %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "health-2",
            "name" => "run_script",
            "input" => %{"script" => "local status, err = script_health(); return status"}
          }
        ]
      },
      %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "health-2", "content" => "ok"}
        ]
      }
    ]
  end

  defp credential(%Scope{} = scope, %Agent{provider: provider}) when is_binary(provider) do
    case Credential.fetch(scope, provider) do
      {:ok, credential} -> credential
      {:error, _reason} -> %{}
    end
  end

  defp credential(_scope, _agent), do: %{}

  # Only the fields the named provider uses: no token pair on the wire for an
  # api-key provider.
  defp credential_fields(%{"type" => "api_key", "key" => key}), do: %{"api_key" => key}

  # A ChatGPT subscription, from the integration the user connected. Without it
  # the harness falls back to the machine's own CLI login. Optional fields are
  # sent only when present.
  defp credential_fields(%{"type" => "oauth"} = credential) do
    %{
      "access" => credential["access"],
      "refresh" => credential["refresh"],
      "expires" => credential["expires"]
    }
    |> put_present("account_id", credential["accountId"])
    |> put_present("id_token", credential["idToken"])
    |> put_present("last_refresh", credential["refreshedAt"])
  end

  defp credential_fields(_credential), do: %{}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp model(%Agent{model: model}) when is_binary(model) and model != "", do: model

  defp model(%Agent{role: role, provider: provider}) when is_atom(role) and not is_nil(role) do
    Enum.find_value(Defaults.for_role(role), fn {candidate, model} ->
      candidate == provider && model
    end)
  end

  defp model(_agent), do: nil
end
