defmodule CodeMySpec.Agents do
  @moduledoc """
  The agents CodeMySpec has started, and the credential each one runs on.

  Server-side half of starting a coding agent. Owns which agents exist, on which
  working copy and on which provider; mints the per-copy Pi configuration from
  the account's integration; and holds the record a conversation attaches to.
  `CmsHarness.Agents` is the other half — the OS process on the device — reached
  over the harness channel. Same split as Provisioning: state and ordering live
  here, execution happens on the box, because the server holds no disk and
  cannot start a process on somebody's machine.

  ## Starting is refused before it is attempted

  `start_agent/2` resolves the credential first and refuses if there is not a
  usable one. That ordering is the point rather than an optimisation. An agent
  started without a working credential fails on its first model call — minutes
  later, in a log nobody is reading — which is why `agent.sh` ended up grepping
  its own output for expired-session text and bailing: retrying an
  unauthenticated agent burns twelve minutes to reach the same answer with the
  cause buried under supervisor noise.

  The two refusals are kept apart for the same reason. `:not_connected` sends
  someone to connect a provider; `:reconnect_required` sends them to reconnect
  one they know they connected. Reporting the second as the first sends them to
  set up something that already exists.

  ## Started means watchable

  A pid proves a fork. It does not prove the credential resolved, that a model
  answered, or that the harness was ever joined, and every one of those failures
  is quiet from the caller's side. So an agent is recorded `:starting` and only
  becomes `:running` when the device says it is — and its turns arrive in
  `Conversations` the same way a Claude Code agent's do, through
  `AgentHarness.relay_up/2`. An agent the server cannot observe is
  indistinguishable from one that never started.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Credential
  alias CodeMySpec.Agents.PiConfig
  alias CodeMySpec.Agents.Providers
  alias CodeMySpec.Users.Scope

  @type start_error ::
          :missing_active_project
          | :not_connected
          | :reconnect_required
          | :unknown_provider
          | Ecto.Changeset.t()
          | term()

  @doc """
  Subscribes to scoped notifications about agents.

    * {:agent_started, %Agent{}}
    * {:agent_stopped, %Agent{}}
  """
  def subscribe(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(scope))
  end

  defdelegate list_agents(scope), to: AgentsRepository
  defdelegate list_running(scope), to: AgentsRepository
  defdelegate fetch_agent(scope, id), to: AgentsRepository
  defdelegate providers(), to: Providers, as: :names

  @doc """
  Starts an agent on a working copy, on the provider the caller named.

  The provider is an argument rather than ambient state. A machine-wide default
  answers correctly right up until two callers want different things, and then
  spends the wrong subscription for one of them — which nobody notices until a
  quota or a bill does.
  """
  @spec start_agent(Scope.t(), map()) :: {:ok, Agent.t()} | {:error, start_error()}
  def start_agent(%Scope{} = scope, %{provider: provider} = attrs) do
    with {:ok, credential} <- Credential.fetch(scope, provider),
         {:ok, agent} <- AgentsRepository.create_agent(scope, base_attrs(scope, attrs)),
         {:ok, config_dir} <- PiConfig.mint(agent, credential),
         {:ok, agent} <- AgentsRepository.update_agent(scope, agent, %{config_dir: config_dir}) do
      broadcast(scope, {:agent_started, agent})
      {:ok, agent}
    end
  end

  @doc """
  Stops one agent, and only that one.

  Stopping is only useful if it stops the right one: a stop that reaps the tree,
  or kills by name and catches a sibling, looks identical from the caller's side
  and is worse than having no stop at all.
  """
  @spec stop_agent(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Agent.t()} | {:error, :not_found | :cross_project | Ecto.Changeset.t()}
  def stop_agent(%Scope{} = scope, id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         {:ok, stopped} <-
           AgentsRepository.update_agent(scope, agent, %{status: :stopped, os_pid: nil}) do
      broadcast(scope, {:agent_stopped, stopped})
      {:ok, stopped}
    end
  end

  @doc """
  Records what the device reported back about an agent it was asked to start.
  """
  @spec record_started(Scope.t(), Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, :cross_project | Ecto.Changeset.t()}
  def record_started(%Scope{} = scope, %Agent{} = agent, %{os_pid: os_pid}) do
    AgentsRepository.update_agent(scope, agent, %{status: :running, os_pid: os_pid})
  end

  defp base_attrs(%Scope{} = scope, attrs) do
    %{
      engine: Map.get(attrs, :engine, :pi),
      provider: Map.fetch!(attrs, :provider),
      working_copy: Map.get(attrs, :working_copy) || scope.cwd,
      status: :starting
    }
  end

  defp broadcast(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(scope), message)
  end

  defp topic(%Scope{active_project_id: project_id}), do: "agents:#{project_id}"
end
