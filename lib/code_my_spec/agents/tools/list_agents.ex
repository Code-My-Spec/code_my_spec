defmodule CodeMySpec.Agents.Tools.ListAgents do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Tools.Responses, as: AgentsMapper

  @impl true
  def name, do: "list_agents"

  @impl true
  def description do
    """
    What is running on this project, and on which working copy.

    Nothing could answer this before: an agent was started by hand with
    `docker exec -d`, supervised by a bash loop, and the application found out a
    run had ended by noticing it stopped reporting.

    This is what the server was told. The device's own answer arrives over the
    harness channel as `agents_running`, which is a projection of Presence on the
    lane topics — a lane is joined for exactly as long as it is alive. So a row
    here that the harness has stopped reporting is already marked stopped by the
    time anybody asks.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> AgentsMapper.listing(listed(scope))
      {:error, reason} -> AgentsMapper.error(reason, nil)
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      {:ok, Enum.map(listed(scope), &row/1)}
    end
  end

  defp row(a) do
    %{
      "id" => a.id,
      "role" => to_string(a.role),
      "engine" => to_string(a.engine),
      "status" => to_string(a.status),
      "working_copy" => a.working_copy,
      "provider" => a.provider,
      "model" => a.model,
      "off_at" => a.off_at && DateTime.to_iso8601(a.off_at)
    }
  end

  # Every agent on duty, whether or not its process is up, and any still
  # running though turned off. An agent asked for that never came up is listed,
  # so it can be found and cancelled (criterion 975); listing only present ones
  # (v2.0.372) hid exactly those.
  defp listed(scope),
    do: Enum.uniq_by(Agents.list_on_duty(scope) ++ Agents.list_running(scope), & &1.id)
end
