defmodule CodeMySpec.Activity do
  @moduledoc """
  Persisted, append-only log of provisioning and configuration changes,
  attributed to the person or agent that made them.

  Every provision, check, deploy, credential save, secret write and
  environment edit a project sees is one row here. There is no update and
  no delete — `record/4` is the only write this module exposes, and a row
  is wrong only in the sense that a bad statement in a ledger is: the fix
  is a later, correcting entry, never erasing the first one.

  ## Secrets by name only

  `record/4`'s `summary` is whatever the caller builds — this module does
  not inspect it. The discipline that a secret write's summary names the
  key and never the value lives at each call site (`ConsoleLive`'s
  `put_secret` handler, `ImportAgeKey`), the same way it already has to
  for the flash message the same write produces.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Agents, CodeMySpec.Repo, CodeMySpec.Users.Scope],
    exports: [Entry]

  import Ecto.Query

  alias CodeMySpec.Activity.Entry
  alias CodeMySpec.Agents
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Record one entry against the scope's active project.

  `opts[:environment]` is nil for a project-wide action (a credential
  save, adding an environment itself). `opts[:agent_id]` is the calling
  agent's id when an MCP tool is acting rather than a person at the
  console — the same id `Agents.actor/2`'s other callers already thread
  through from `frame.assigns[:agent_id]`.
  """
  @spec record(Scope.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(%Scope{active_project_id: project_id} = scope, kind, resource, summary, opts \\ [])
      when is_binary(project_id) do
    %Entry{}
    |> Entry.changeset(%{
      project_id: project_id,
      environment: Keyword.get(opts, :environment),
      resource: to_string(resource),
      kind: to_string(kind),
      actor: Agents.actor(scope, Keyword.get(opts, :agent_id)),
      summary: summary
    })
    |> Repo.insert()
  end

  @doc """
  Every entry for the scope's active project, newest first. `opts[:environment]`
  narrows to one environment; omitted or nil, every entry regardless of
  environment (project-wide entries included either way).
  """
  @spec list_for_project(Scope.t(), keyword()) :: [Entry.t()]
  def list_for_project(%Scope{active_project_id: project_id}, opts \\ []) do
    project_id
    |> project_query()
    |> environment_scoped(Keyword.get(opts, :environment))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Every entry for one resource on the scope's active project, newest
  first — a resource tab's own history, nothing from any other resource.
  """
  @spec list_for_resource(Scope.t(), atom() | String.t()) :: [Entry.t()]
  def list_for_resource(%Scope{active_project_id: project_id}, resource) do
    project_id
    |> project_query()
    |> where([e], e.resource == ^to_string(resource))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  defp project_query(project_id), do: from(e in Entry, where: e.project_id == ^project_id)

  defp environment_scoped(query, nil), do: query
  defp environment_scoped(query, environment), do: where(query, [e], e.environment == ^environment)
end
