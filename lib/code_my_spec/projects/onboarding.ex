defmodule CodeMySpec.Projects.Onboarding do
  @moduledoc "Reads and saves resumable setup decisions for the active project."
  import Ecto.Changeset
  alias CodeMySpec.{Devices, Repo}
  alias CodeMySpec.Accounts.Authorization
  alias CodeMySpec.Projects.{Project, Source}
  alias CodeMySpec.Users.Scope

  def subscribe(%Scope{} = scope) do
    with {:ok, _} <- fetch(scope) do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(scope))
    end
  end

  defp topic(scope), do: "project:#{scope.active_project_id}:onboarding"

  def fetch(
        %Scope{user: %{id: _}, active_account_id: account_id, active_project_id: project_id} =
          scope
      )
      when is_binary(account_id) and is_binary(project_id) do
    if Authorization.authorize(:read_account, scope, account_id) do
      case Repo.get_by(Project, id: project_id, account_id: account_id) do
        nil -> {:error, :not_found}
        project -> {:ok, project}
      end
    else
      {:error, :not_found}
    end
  end

  def fetch(%Scope{}), do: {:error, :not_found}

  @doc "Omitted embeds are retained. An explicit sources list replaces the selected sources."
  def save(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, project} <- fetch(scope) do
      project
      |> change()
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> validate_length(:name, max: 255)
      |> cast_embed(:onboarding)
      |> cast_embed(:sources,
        with: fn source, attrs ->
          source |> Source.changeset(attrs) |> validate_device(scope)
        end
      )
      |> Repo.update()
      |> broadcast(scope)
    end
  end

  @doc "The next onboarding step, derived from saved choices and a durable setup handoff."
  def phase(%Project{onboarding: nil}), do: :synopsis

  def phase(%Project{onboarding: state} = project) do
    cond do
      is_nil(state.description) or String.trim(state.description) == "" -> :synopsis
      is_nil(state.starting_point) or is_nil(state.destination) -> :build_destination
      state.starting_point == :existing and project.sources == [] -> :build_destination
      is_nil(state.setup_agent_id) or is_nil(state.setup_started_at) -> :setup_handoff
      true -> :stories
    end
  end

  @doc "Record an accepted setup handoff. Not writable through the choices tool."
  def record_handoff(scope, agent_id) do
    with {:ok, project} <- fetch(scope) do
      state = %{
        setup_agent_id: agent_id,
        setup_started_at: project.onboarding.setup_started_at || DateTime.utc_now()
      }

      project |> change() |> put_embed(:onboarding, state) |> Repo.update() |> broadcast(scope)
    end
  end

  defp validate_device(changeset, scope) do
    id = get_field(changeset, :device_id)

    if get_field(changeset, :kind) == :local and is_binary(id) and
         is_nil(Devices.get_harness_device(scope, id)) do
      add_error(changeset, :device_id, "is not an accessible device")
    else
      changeset
    end
  end

  defp broadcast({:ok, project} = result, scope) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      topic(scope),
      {:project_onboarding_updated, project}
    )

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "user:#{scope.user.id}:projects",
      {:updated, project}
    )

    result
  end

  defp broadcast(result, _scope), do: result
end
