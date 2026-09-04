defmodule CodeMySpec.Provisioning.ServerView do
  @moduledoc """
  What setup did, asked from the server's side rather than the project's.

  ## The grain problem this solves

  `provisioning_steps` is one row per project per step, and its resources are
  an embedded list. That is the right shape for running the sequence — a run
  belongs to a project — and the wrong shape for the question "what is on this
  machine", which is what someone looking at a box actually asks.

  The join already exists and is exact, so no guessing is involved:
  `provisioning_environments.server_name` names the box, and every step that
  fans out tags its resources `environment=<name>`. An environment row gives
  the (project, environment) pairs a server carries; the tag says which of that
  project's resources belong to each.

  Deliberately not fuzzy-matched on location strings. A certificate attached to
  the wrong box is worse than one attached to none: it would state, on the page
  someone opened to find out where a certificate lives, that it lives somewhere
  it does not.

  ## Why steps come back too, not only resources

  A resource is evidence something exists. Its absence is not evidence of
  anything — the step may have failed, or may never have run, and those need
  different things from the reader.

  The steps come from `Provisioning.plan/2` rather than from the table, and
  that matters: **a step that never ran has no row at all**. Reading rows
  directly would drop it from the page entirely, which is the quietest
  possible way for backups to be off. `plan/2` merges the sequence with what
  is persisted and defaults the gaps to `:not_started`, so "never ran" is
  something the page can say rather than something it omits.
  """

  import Ecto.Query

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.Environment
  alias CodeMySpec.Repo
  alias CodeMySpec.Servers.Server
  alias CodeMySpec.Users.Scope

  @type entry :: %{
          project_id: Ecto.UUID.t(),
          project_name: String.t(),
          environment: String.t(),
          steps: [map()],
          resources: [map()]
        }

  @doc """
  Everything the account's projects have recorded against a named server.

  One entry per (project, environment) pointed at the box, because a shared
  host carries more than one and they succeed and fail independently. An empty
  list means nothing claims this server — which is a real answer, and the one
  that matters for a box nobody remembers provisioning.
  """
  @spec for_server(Scope.t(), String.t()) :: [entry()]
  def for_server(%Scope{active_account_id: account_id} = scope, server_name)
      when is_binary(account_id) and is_binary(server_name) do
    account_id
    |> environments_on(server_name)
    |> Enum.map(&entry_for(scope, &1))
    |> Enum.sort_by(&{&1.project_name, &1.environment})
  end

  def for_server(_scope, _server_name), do: []

  @doc """
  Names of the projects currently pointed at a server, deduplicated.

  What retiring a server refuses against — cheaper than `for_server/2`, which
  also walks each project's whole step plan to build the entries this only
  needs the names out of.
  """
  @spec projects_using(Scope.t(), String.t()) :: [String.t()]
  def projects_using(%Scope{active_account_id: account_id}, server_name)
      when is_binary(account_id) and is_binary(server_name) do
    account_id
    |> environments_on(server_name)
    |> Enum.map(& &1.project.name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def projects_using(_scope, _server_name), do: []

  # Two ways an environment ends up pointed at this box, and both have to
  # match. `e.server_name` is what a project's own successful run writes back
  # (`record_environment_server/5`) — the truth once setup has actually
  # reached the provider. `e.server_id` is what linking writes immediately
  # (`LinkServer`/`EnvironmentRepository.put`), before any run has happened at
  # all — the hard line's whole point is that a linked-but-not-yet-run
  # environment is real and grantable, so this page has to see it too, not
  # only the ones a run already touched.
  defp environments_on(account_id, server_name) do
    base =
      Environment
      |> join(:inner, [e], p in Project, on: p.id == e.project_id)
      |> select([e, p], %{project: p, environment: e.name})

    base
    |> by_name_or_id(account_id, server_name, server_id_for(account_id, server_name))
    |> Repo.all()
  end

  defp by_name_or_id(query, account_id, server_name, nil) do
    where(query, [e, p], p.account_id == ^account_id and e.server_name == ^server_name)
  end

  defp by_name_or_id(query, account_id, server_name, server_id) do
    where(
      query,
      [e, p],
      p.account_id == ^account_id and
        (e.server_name == ^server_name or e.server_id == ^server_id)
    )
  end

  defp server_id_for(account_id, server_name) do
    Server
    |> where([s], s.account_id == ^account_id and s.name == ^server_name)
    |> select([s], s.id)
    |> Repo.one()
  end

  defp entry_for(%Scope{} = scope, %{project: project, environment: environment}) do
    # Re-scoped to the project that owns the environment, not the one the
    # viewer happens to have open. A box is account-grain and can carry
    # projects the reader is not currently working in — which is the case
    # story 986 builds deliberately.
    project_scope = %{scope | active_project: project, active_project_id: project.id}

    steps = Provisioning.plan(project_scope, Provisioning.setup_options(project))

    %{
      project_id: project.id,
      project_name: project.name,
      environment: environment,
      steps: steps,
      resources: resources_for(steps, environment)
    }
  end

  # A step that does not fan out — the repository, the domain — records
  # resources with no environment tag. Those belong to the project rather than
  # to one of its boxes, so they are left off a server's page rather than
  # attributed to whichever environment happened to be asking.
  defp resources_for(steps, environment) do
    for step <- steps,
        resource <- step.resources || [],
        tagged_environment(resource) == environment,
        do: resource |> Map.from_struct() |> Map.put(:step, step.key)
  end

  defp tagged_environment(%{identifier: identifier}) when is_binary(identifier) do
    case Regex.run(~r/environment=([a-z0-9-]+)/, identifier) do
      [_, environment] -> environment
      nil -> nil
    end
  end

  defp tagged_environment(_resource), do: nil
end
