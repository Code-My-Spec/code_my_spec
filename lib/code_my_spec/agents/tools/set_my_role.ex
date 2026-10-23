defmodule CodeMySpec.Agents.Tools.SetMyRole do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "set_my_role"

  @impl true
  def description do
    """
    Take the role you agreed with the person: main, coding, qa or product.

    For a Claude Code or Codex session in a terminal, which joins as this project's main
    agent by default. Ask the person which role you should play before changing
    it. Any role is open on any working copy, even one another agent holds.
    """
  end

  @impl true
  def params do
    %{
      role: {:required, {:enum, ~w(main coding qa product)}},
      session_id: {:meta, :string, [description: "Injected by hook — do not set manually"]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, agent} <- caller(scope, params, context),
         {:ok, agent} <- Agents.set_terminal_role(scope, agent, MapAccess.get(params, :role)) do
      {:ok, "You are now this project's #{agent.role} agent (#{agent.id})."}
    else
      {:error, :not_a_terminal_agent} ->
        {:error, "Only a terminal session chooses its role; an agent we start keeps its seat."}

      {:error, :no_terminal_agent} ->
        {:error,
         "No agent is registered for this session. It registers when the session starts; " <>
           "restart the session in a working copy CodeMySpec serves."}

      {:error, reason} ->
        CodeMySpec.Tools.error(reason)
    end
  end

  defp caller(scope, params, context) do
    id =
      Map.get(context, :agent_id) ||
        Agents.terminal_agent_id(scope, MapAccess.get(params, :session_id))

    case id && Agents.fetch_agent(scope, id) do
      {:ok, agent} -> {:ok, agent}
      _ -> {:error, :no_terminal_agent}
    end
  end
end
