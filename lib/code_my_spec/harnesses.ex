defmodule CodeMySpec.Harnesses do
  @moduledoc """
  The working copies serving a project.

  One entry per checkout, minted the first time that checkout joins and
  presented by it on every join after. The harness writes the id it is given
  into a gitignored file in the working copy, so a restart is the same harness
  and a fresh clone is correctly a new one.

  ## Why the server issues it

  Story 727's decided question, and every client-derived alternative fails a
  real case: a checkout path collides when two containers both sit at
  `/workspace/app`; host+path collides for exactly the containers whose
  hostnames are generated; a Claude Code session id churns, orphaning rows, and
  would split a parent agent from its subagents. The case that settles it is a
  local agent and a cloud agent on the same branch — same path, different
  machines, different uncommitted state — which nothing derivable from the
  checkout alone can tell apart.

  So the client never invents one. It announces itself, is issued an id, and
  keeps it.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Harnesses.Harness
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  The harness for this id, or a new one if the caller has none.

  Two shapes in one call because the join has two shapes: a checkout that has
  never connected presents `nil` and is minted one, and a checkout that has
  presents its id and is recognised.

  An id that names no harness — a row deleted while its working copy still had
  the file — mints a new one rather than failing. The alternative is a checkout
  that cannot serve until somebody deletes a file it has no reason to suspect,
  and the cost of the new id is a resync, which the harness does on join
  anyway.
  """
  @spec issue(Scope.t(), String.t() | nil, keyword()) :: {:ok, Harness.t()} | {:error, term()}
  def issue(%Scope{active_project_id: project_id}, harness_id, opts \\ [])
      when is_binary(project_id) do
    label = Keyword.get(opts, :label)

    case existing(project_id, harness_id) do
      nil -> create(project_id, label)
      harness -> touch(harness, label)
    end
  end

  # Namespaces the derived id so it cannot collide with a minted one and so the
  # same project always resolves to the same row.
  @default_namespace "cms.harness.unnamed-working-copy."

  @doc """
  The project's harness for writers that do not name a working copy.

  A nil object, and an honest one: plenty of writers legitimately have no
  checkout to point at — a mix task, the web UI, a fixture — and before the
  grain change *every* writer was one of them. They all mean the same thing,
  "the project's working copy, whichever that is", so they share one row rather
  than each inventing a checkout that does not exist.

  The id is derived from the project id, so this is idempotent without a lookup
  and the same project always lands on the same harness. `last_seen_at` stays
  nil because nothing ever joins as this one — that is what distinguishes it
  from a real checkout in the operator's list.

  Not a replacement for a real harness. Two *named* checkouts stay isolated;
  this only stops unnamed writers from having to invent an identity in order to
  write a row.
  """
  @spec ensure_default(Scope.t()) :: Ecto.UUID.t()
  def ensure_default(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    id = default_id(project_id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Through the schema, so Ecto casts the ids — `insert_all` only wants
    # pre-dumped binaries when it is given a raw table name.
    Repo.insert_all(
      Harness,
      [
        %{
          id: id,
          project_id: project_id,
          label: "the project's working copy",
          last_seen_at: nil,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:id]
    )

    id
  end

  @doc "The id `ensure_default/1` resolves to, without touching the database."
  @spec default_id(Ecto.UUID.t()) :: Ecto.UUID.t()
  def default_id(project_id) when is_binary(project_id) do
    <<bytes::binary-16, _rest::binary>> =
      :crypto.hash(:sha256, @default_namespace <> project_id)

    Ecto.UUID.load!(bytes)
  end

  @doc """
  Every working copy serving this project, most recently active first.

  The order is the operator's default view — criterion 739 — and it is the
  right default because it needs no configuration and stays correct for a
  checkout nobody thought to classify.
  """
  @spec list_harnesses(Scope.t()) :: [Harness.t()]
  def list_harnesses(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Repo.all(
      from h in Harness,
        where: h.project_id == ^project_id,
        order_by: [desc_nulls_last: h.last_seen_at, desc: h.inserted_at]
    )
  end

  @doc "The harness the operator sees unless they ask for another, or `nil`."
  @spec most_recent(Scope.t()) :: Harness.t() | nil
  def most_recent(%Scope{} = scope), do: scope |> list_harnesses() |> List.first()

  @doc """
  The scope a page showing files or problems should read with.

  Those are per working copy, so a page holding a project-wide scope shows every
  checkout's rows merged — the same path listed once per checkout, with nothing
  saying which is which, and one checkout's failures sitting against another's
  code. Defaulting to the most recently active harness makes the page describe
  one checkout again.

  Most recent rather than a stored preference because it needs no configuration
  and stays right for a checkout nobody thought to classify — criterion 739.
  A project with no harness keeps a project-wide scope, which is the honest
  answer when nothing has ever synced.
  """
  @spec viewing(Scope.t() | nil) :: Scope.t() | nil
  def viewing(nil), do: nil

  def viewing(%Scope{active_project_id: nil} = scope), do: scope

  def viewing(%Scope{} = scope) do
    case most_recent(scope) do
      nil -> scope
      harness -> %{scope | active_harness_id: harness.id}
    end
  end

  # Scoped by project as well as id: an id from one project must not resolve
  # against another's, or a misconfigured checkout would silently adopt a
  # harness belonging to a project it has nothing to do with.
  defp existing(_project_id, nil), do: nil

  defp existing(project_id, harness_id) do
    case Ecto.UUID.cast(harness_id) do
      {:ok, id} -> Repo.get_by(Harness, id: id, project_id: project_id)
      :error -> nil
    end
  end

  defp create(project_id, label) do
    %Harness{}
    |> Harness.changeset(%{project_id: project_id, label: label, last_seen_at: now()})
    |> Repo.insert()
  end

  # The label is refreshed on every join because it can legitimately change —
  # a checkout moves, a container is recreated with a new hostname — and it is
  # display only, so following it costs nothing and keeps the operator's picker
  # honest. A join that does not carry one leaves the last known label alone.
  defp touch(harness, nil), do: save(harness, %{last_seen_at: now()})
  defp touch(harness, label), do: save(harness, %{last_seen_at: now(), label: label})

  defp save(harness, attrs) do
    harness
    |> Harness.changeset(attrs)
    |> Repo.update()
  end

  defp now, do: DateTime.utc_now()
end
