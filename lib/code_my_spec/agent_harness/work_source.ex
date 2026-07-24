defmodule CodeMySpec.AgentHarness.WorkSource do
  @moduledoc """
  Turns lane state into dispatched work. The Pi harness is dumb; the WorkSource
  decides what each parked lane does next.

    * `lane_idle/2` — a lane settled. Resolve the next actionable requirement for
      that role and, if one exists, dispatch it to the lane's topic.
    * `work_result/3` — the task lifecycle already advanced the graph server-side
      (`evaluate_task` / `submit_qa_result`); just poke the lane to pull again.
    * `set_interactive/2` / `interactive_role/1` — track which lane a sustained
      user interview (e.g. `product`) was dispatched to, so a human reply from the
      server routes to it (falling back to the manager).

  Requirement resolution reuses the same path `get_next_requirement` uses:
  `RequirementGraph.next_actionable/1` filtered to the role's `subagent_role`,
  rendered to directive text via `RequirementsMapper`. Only the sub-agent roles
  (`coding` / `spec_writer` / `qa`) auto-pull; `product` is interview-driven and
  `manager` is the puller, so both resolve to `:none`.
  """

  use GenServer
  require Logger

  alias CodeMySpec.AgentHarness
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  # Role string -> requirement `subagent_role`. Roles absent here don't auto-pull.
  @auto_pull_roles %{"coding" => :coding, "spec_writer" => :spec_writer, "qa" => :qa}

  # ---- API ------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lane_idle(external_id, role), do: GenServer.cast(__MODULE__, {:lane_idle, external_id, role})

  def work_result(external_id, role, payload),
    do: GenServer.cast(__MODULE__, {:work_result, external_id, role, payload})

  def set_interactive(external_id, role),
    do: GenServer.cast(__MODULE__, {:set_interactive, external_id, role})

  @doc "The lane a human reply for this session should route to (default: manager)."
  def interactive_role(external_id),
    do: GenServer.call(__MODULE__, {:interactive_role, external_id})

  # ---- Server ---------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{interactive: %{}}}

  @impl true
  def handle_cast({:lane_idle, external_id, role}, state) do
    case next_for_role(external_id, role) do
      {:ok, %{prompt: prompt, requirement_name: req}} ->
        AgentHarness.route_to_lane(external_id, role, "user_message", %{
          "text" => prompt,
          "requirement_name" => req
        })

      :none ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:work_result, external_id, role, _payload}, state),
    do: handle_cast({:lane_idle, external_id, role}, state)

  def handle_cast({:set_interactive, external_id, role}, state),
    do: {:noreply, put_in(state, [:interactive, external_id], role)}

  @impl true
  def handle_call({:interactive_role, external_id}, _from, state),
    do: {:reply, Map.get(state.interactive, external_id, "manager"), state}

  # ---- Requirement resolution -----------------------------------------------

  defp next_for_role(external_id, role) do
    with role_atom when not is_nil(role_atom) <- Map.get(@auto_pull_roles, role),
         {:ok, scope} <- resolve_scope(external_id) do
      scope
      |> RequirementGraph.next_actionable()
      |> Enum.filter(&(&1.subagent_role == role_atom))
      |> case do
        [node | _] ->
          {:ok,
           %{
             requirement_name: node.name,
             prompt: RequirementsMapper.format_next_requirements([node], %{})
           }}

        [] ->
          :none
      end
    else
      _ -> :none
    end
  rescue
    e ->
      Logger.warning("[WorkSource] next_for_role failed for #{role}: #{Exception.message(e)}")
      :none
  end

  # Same working-dir resolution as the socket handshake: external_id = "pi:<cwd>".
  defp resolve_scope("pi:" <> working_dir) when working_dir != "" do
    with {:ok, project} <- Projects.get_project_by_local_path(working_dir) do
      Scope.for_local_project(project)
    end
  end

  defp resolve_scope(_external_id), do: {:error, :no_working_dir}
end
