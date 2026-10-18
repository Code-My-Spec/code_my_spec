defmodule CodeMySpec.McpServers.MainAgent.Tools.RuntimeDiagnostics do
  @moduledoc """
  Read the serving VM's boot revision, checkout HEAD, process identity and
  effective grants for an agent on this project. Boot revision is distinct
  from hot-reloaded module fingerprints. Browser capability and the actual
  wrapper discovery response are reported separately. No credentials or
  state changes. Available to main and operator sessions.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.BootVersion
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs
  alias CodeMySpec.McpServers.Validators

  schema do
    field :agent_id, :string, required: true, description: "Agent on this project to inspect"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         :ok <- authorize(scope, frame.assigns[:agent_id]),
         {:ok, agent} <- Agents.fetch_agent(scope, Map.get(params, :agent_id)) do
      grants = Agents.tools_of(scope, agent)
      target_frame = %{frame | assigns: Map.put(frame.assigns, :agent_id, agent.id)}
      {:reply, discovery, _} = ToolDocs.execute(%{names: ["run_browser_script"]}, target_frame)

      result = %{
        serving: BootVersion.runtime_snapshot(),
        loaded_modules: fingerprints(),
        agent: %{
          id: agent.id,
          role: agent.role,
          working_copy_id: agent.working_copy_id,
          effective_grants: grants || "all",
          browser_capability: is_nil(grants) or Layer.browser_capability() in grants,
          browser_wrapper_discovery: Response.to_protocol(discovery)["content"]
        }
      }

      {:reply, Response.tool() |> Response.text(Jason.encode!(result)), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error(inspect(reason)), frame}
    end
  end

  defp authorize(_scope, nil), do: :ok

  defp authorize(scope, caller_id) do
    case Agents.fetch_agent(scope, caller_id) do
      {:ok, %{role: :main}} -> :ok
      _ -> {:error, :main_only}
    end
  end

  defp fingerprints do
    Map.new([Agents, ToolDocs, Layer], fn module ->
      {inspect(module), Base.encode16(module.module_info(:md5), case: :lower)}
    end)
  end
end
