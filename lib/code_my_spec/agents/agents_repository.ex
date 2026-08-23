defmodule CodeMySpec.Agents.AgentsRepository do
  @moduledoc """
  Queries over the agents CodeMySpec started, scoped to the active project.

  Every read is project-scoped. An agent names a working copy and a credential,
  and both are tenant property — on a shared host the whole point of the record
  is that one tenant's agent is not reachable from another's.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @spec list_agents(Scope.t()) :: [Agent.t()]
  def list_agents(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  def list_agents(%Scope{}), do: []

  @doc """
  The agents this project believes are running.

  Separate from `list_agents/1` because "what is running" and "what has ever
  run" are different questions and the first is the one an operator asks.
  """
  @spec list_running(Scope.t()) :: [Agent.t()]
  def list_running(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id and a.status in [:starting, :running])
    |> order_by([a], asc: a.working_copy, asc: a.role)
    |> Repo.all()
  end

  def list_running(%Scope{}), do: []

  @spec fetch_agent(Scope.t(), Ecto.UUID.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def fetch_agent(%Scope{active_project_id: project_id}, id)
      when is_binary(project_id) and is_binary(id) do
    Agent
    |> where([a], a.project_id == ^project_id and a.id == ^id)
    |> Repo.one()
    |> wrap_agent()
  end

  def fetch_agent(%Scope{}, _id), do: {:error, :not_found}

  defp wrap_agent(nil), do: {:error, :not_found}
  defp wrap_agent(%Agent{} = agent), do: {:ok, agent}

  @spec create_agent(Scope.t(), map()) ::
          {:ok, Agent.t()} | {:error, :missing_active_project | Ecto.Changeset.t()}
  def create_agent(%Scope{active_project_id: nil}, _attrs), do: {:error, :missing_active_project}

  def create_agent(%Scope{} = scope, attrs) do
    attrs =
      attrs
      |> Map.put(:project_id, scope.active_project_id)
      |> Map.put(:account_id, scope.active_account_id)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_agent(Scope.t(), Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, :cross_project | Ecto.Changeset.t()}
  def update_agent(
        %Scope{active_project_id: project_id},
        %Agent{project_id: project_id} = agent,
        attrs
      ) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  def update_agent(%Scope{}, %Agent{}, _attrs), do: {:error, :cross_project}
end
