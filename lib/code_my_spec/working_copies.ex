defmodule CodeMySpec.WorkingCopies do
  @moduledoc """
  The working copies serving a project.

  One entry per checkout, minted the first time that checkout joins and
  presented by it on every join after. The harness writes the id it is given
  into a gitignored file in the working copy, so a restart is the same harness
  and a fresh clone is correctly a new one.

  The server issues the id; the client never invents one. Every client-derived
  key fails a real case (paths collide across containers, session ids churn).
  See knowledge/promotion, "Working copies".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents.RoleProfile,
      CodeMySpec.AppInstances,
      CodeMySpec.Analysis.HarnessRegistry,
      CodeMySpec.Devices,
      CodeMySpec.Encrypted.Binary,
      CodeMySpec.ExecutionContexts,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  import Ecto.Query, warn: false

  require Logger

  alias CodeMySpec.AppInstances
  alias CodeMySpec.AppInstances.AppInstance
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  # `CmsHarness.Config.label/1`'s fallback, "the harness at <root> on <host>",
  # sent by an unnamed harness. `touch/2` uses it to tell that shape from a
  # name a person chose; `display_name/1` matches the same shape to shorten it.
  @auto_label_pattern ~r{^the harness at\s+\S+ on\s+\S+}

  @doc """
  The harness for this id, or a new one if the caller has none.

  Two shapes in one call because the join has two shapes: a checkout that has
  never connected presents `nil` and is minted one, and a checkout that has
  presents its id and is recognised.

  An id that names no harness anywhere (a row deleted while the checkout kept
  its file) is recreated under that same id, so the checkout and the server
  keep agreeing about who it is; one held by another project is never taken
  over and is minted fresh. A join with no id is minted, below. Minted every time, never
  matched back by device and root — story 1000's criterion 5 settled that a
  join with no id is always a new agent, even from a path and device the
  server has seen, because the alternative merges two different agents that
  share one. `by_root/2` is the narrower, explicit lookup for a caller that
  names its own path on purpose.

  Refuses a root that is a checkout's own `.code_my_spec/` and, when minting,
  a join that names no device (`{:error, :no_device}`).
  """
  @spec issue(Scope.t(), String.t() | nil, keyword()) :: {:ok, WorkingCopy.t()} | {:error, term()}
  def issue(%Scope{active_project_id: project_id}, working_copy_id, opts \\ [])
      when is_binary(project_id) do
    label = Keyword.get(opts, :label)

    with :ok <- refuse_metadata_dir(opts[:root]) do
      case existing(project_id, working_copy_id) do
        nil -> create(project_id, label, opts[:device], presented_id(working_copy_id, opts))
        harness -> touch(harness, label)
      end
    end
  end

  # A checkout's own `.code_my_spec/` is not a checkout: registered as one it
  # takes analysis runs that fail with no `mix.exs`. Refused, not normalised to
  # the parent (the caller is confused and that must show), and server-side so
  # every client, however old, is covered.
  defp refuse_metadata_dir(root) when is_binary(root) do
    case Path.basename(String.trim_trailing(root, "/")) do
      ".code_my_spec" ->
        {:error,
         %{
           reason:
             "#{root} is a checkout's own .code_my_spec directory, not a checkout. " <>
               "Registered as a working copy it takes analysis runs the real root " <>
               "should have had, and they fail with no mix.exs to run. Onboard the " <>
               "directory above it."
         }}

      _ ->
        :ok
    end
  end

  defp refuse_metadata_dir(_root), do: :ok

  @doc """
  The checkout at this root on the caller's own machine, or `nil`.

  How callers outside a harness name a checkout (the MCP `start_agent` tool
  passes a root, no id). Scoped to the caller's own device: one root can exist
  on two machines, and a caller naming a path means the path on its own box.
  """
  @spec by_root(Scope.t(), String.t()) :: WorkingCopy.t() | nil
  def by_root(%Scope{active_project_id: project_id} = scope, root)
      when is_binary(project_id) and is_binary(root) and root != "" do
    case fetch(scope.active_working_copy_id) do
      {:ok, %{device_id: device_id}} when is_binary(device_id) ->
        recognised(project_id, device_id, Path.expand(root))

      _ ->
        nil
    end
  end

  def by_root(_scope, _root), do: nil

  @doc """
  Every working copy with this label at this root, whatever its project.

  For the one caller with no scope to give: a copy's own app re-registering
  the QA fixtures `/dev/qa-agents` recorded against its checkout.
  """
  @spec labelled_at(String.t(), String.t()) :: [WorkingCopy.t()]
  def labelled_at(root, label) when is_binary(root) and is_binary(label) do
    root = Path.expand(root)
    Repo.all(from w in WorkingCopy, where: w.root == ^root and w.label == ^label)
  end

  defp recognised(_project_id, nil, _root), do: nil
  defp recognised(_project_id, _device, nil), do: nil
  defp recognised(_project_id, _device, ""), do: nil

  defp recognised(project_id, %Device{id: device_id}, root),
    do: recognised(project_id, device_id, root)

  defp recognised(project_id, device_id, root) when is_binary(device_id) do
    Repo.one(
      from w in WorkingCopy,
        where: w.project_id == ^project_id and w.device_id == ^device_id and w.root == ^root,
        # The oldest: everything else already points at it, and adopting a
        # newer duplicate would strand what was written under the original.
        order_by: [asc: w.inserted_at],
        limit: 1
    )
  end

  defp recognised(_project_id, _device, _root), do: nil

  # Namespaces the derived id so it cannot collide with a minted one and so the
  # same project always resolves to the same row.
  @default_namespace "cms.harness.unnamed-working-copy."

  @doc """
  The project's harness for writers that do not name a working copy.

  A nil object for writers with no checkout to name (a mix task, the web UI, a
  fixture): they share one row rather than each inventing a checkout.

  The id is derived from the project id (`default_id/1`), so this is idempotent
  without a lookup. `last_seen_at` stays nil because nothing ever joins as this
  one, which is what tells it apart from a real checkout.
  """
  @spec ensure_default(Scope.t()) :: Ecto.UUID.t()
  def ensure_default(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    id = default_id(project_id)

    now = DateTime.utc_now()

    # Through the schema, so Ecto casts the ids — `insert_all` only wants
    # pre-dumped binaries when it is given a raw table name.
    Repo.insert_all(
      WorkingCopy,
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

  @doc """
  The harness with this id, with its project loaded.

  Takes no scope: the id *is* the identity, so resolving it must not depend on
  knowing the project or directory. A hook naming an id gets that copy's
  project and root, never one inferred from a path.

  `:error` for a malformed id rather than a raise: the value arrives from a
  header and a caller must be able to tell "you sent nonsense" from "the
  database is down".
  """
  @spec fetch(String.t()) :: {:ok, WorkingCopy.t()} | {:error, :not_found | :invalid_id}
  def fetch(working_copy_id) when is_binary(working_copy_id) do
    case Ecto.UUID.cast(working_copy_id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        case WorkingCopy |> Repo.get(id) |> Repo.preload(:project) do
          nil -> {:error, :not_found}
          harness -> {:ok, harness}
        end
    end
  end

  def fetch(_), do: {:error, :invalid_id}

  @doc """
  Resolves the execution context for the exact working copy selected by `scope`.

  Both active ids must be present, and the fetched copy must belong to the
  active project. For a rooted copy, resolution prefers its id-specific
  registration, then a registration for its root, then a synthesized harness
  environment. This deliberately ignores `scope.cwd`,
  the project's registered environment, and other copies. Root registration
  is only a fallback for the already-validated copy root; it is not a project
  environment override. Invalid, missing, mismatched, or unrooted copies
  return `nil`.
  """
  @spec execution_context(Scope.t()) :: ExecutionContext.t() | nil
  def execution_context(%Scope{active_project_id: project_id, active_working_copy_id: copy_id})
      when is_binary(project_id) and is_binary(copy_id) do
    case fetch(copy_id) do
      {:ok, %{project_id: ^project_id, root: root}}
      when is_binary(root) and root != "" ->
        ExecutionContexts.lookup_registered({:working_copy, copy_id}) ||
          ExecutionContexts.lookup_registered({:root, root}) ||
          ExecutionContext.new(:harness, root, ref: %{"harness_id" => copy_id})

      _ ->
        nil
    end
  end

  def execution_context(_scope), do: nil

  @doc """
  The execution context a tool that touches files uses: the caller's working copy,
  else the directory a stdio server was started in, else nil. Nil means the
  tool must not touch a filesystem; see `McpServers.Validators.mcp_working_dir/1`
  for why guessing is worse than refusing.
  """
  @spec tool_execution_context(Scope.t() | nil, String.t() | nil) :: ExecutionContext.t() | nil
  def tool_execution_context(scope, working_dir \\ nil)

  def tool_execution_context(%Scope{active_working_copy_id: id} = scope, _working_dir)
      when not is_nil(id),
      do: execution_context(scope)

  def tool_execution_context(_scope, working_dir) do
    case working_dir || configured_working_dir() do
      nil -> nil
      dir -> ExecutionContext.new(:local, dir)
    end
  end

  @doc "The working directory a stdio server was started in (`CMS_MCP_WORKING_DIR`), or nil."
  @spec configured_working_dir() :: String.t() | nil
  def configured_working_dir, do: Application.get_env(:code_my_spec, :mcp_working_dir)

  @doc "The name of the machine a working copy is on, or nil when it has none on record."
  @spec machine_name(term()) :: String.t() | nil
  def machine_name(working_copy_id) do
    with {:ok, copy} <- fetch(working_copy_id),
         %{device: %Device{} = device} <- Repo.preload(copy, :device) do
      Device.display_name(device)
    else
      _ -> nil
    end
  end

  @doc """
  The story the team on this copy works: the one its story-scope agents
  (coding, QA) hold, or nil when none holds one.

  The team is the only record; the copy stores no active story.
  `Agents.assign_team/3` is the writer. Read schemalessly because `Agents`
  sits above this context. If agents ever disagree, the earliest-started
  one answers.
  """
  @spec team_story_id(Ecto.UUID.t() | nil) :: integer() | nil
  def team_story_id(copy_id) when is_binary(copy_id) do
    roles =
      for role <- RoleProfile.roles(), RoleProfile.scope(role) == :story, do: to_string(role)

    from(a in "agents",
      where:
        a.working_copy_id == type(^copy_id, Ecto.UUID) and a.role in ^roles and
          is_nil(a.retired_at) and not is_nil(a.story_id),
      order_by: [asc: a.inserted_at],
      select: a.story_id,
      limit: 1
    )
    |> Repo.one()
  end

  def team_story_id(_copy_id), do: nil

  @doc "Tell the graph a story selection on this project changed."
  @spec announce_selection(Scope.t()) :: term()
  def announce_selection(%Scope{} = scope),
    do: GraphInputs.announce(scope, "WorkingCopies", [], :project_wide)

  @doc """
  Select a working copy and its recorded root without attaching a runtime.

  Callers that need filesystem access resolve `environment/1` at the operation
  boundary. The scope carries the copy identity, not its execution adapter.
  """
  @spec put_scope(Scope.t(), WorkingCopy.t()) :: Scope.t()
  def put_scope(%Scope{} = scope, %WorkingCopy{} = harness) do
    %{
      scope
      | active_working_copy_id: harness.id,
        cwd: harness.root || scope.cwd
    }
  end

  @doc """
  The checkout this project's own agent runs in, or nil.

  Nil is an ordinary answer: surfaces that need a main copy say there is none
  rather than guessing one.
  """
  @spec main(Scope.t()) :: WorkingCopy.t() | nil
  def main(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Repo.one(from w in WorkingCopy, where: w.project_id == ^project_id and w.main)
  end

  def main(%Scope{}), do: nil

  @doc """
  A scope per project that has designated a main copy, pointed at that
  copy's own harness.

  For sweeps over every project's main checkout (e.g. the periodic
  `FileSync.reconcile_lockfile/2` backstop). Each scope selects its own copy,
  so one offline copy fails alone without taking the sweep down.
  """
  @spec main_copy_scopes() :: [Scope.t()]
  def main_copy_scopes do
    from(w in WorkingCopy, where: w.main, preload: [:project])
    |> Repo.all()
    |> Enum.reject(&is_nil(&1.project))
    |> Enum.map(fn %WorkingCopy{project: project} = copy ->
      %Scope{active_account_id: project.account_id}
      |> project_scoped(project)
      |> put_scope(copy)
    end)
  end

  defp project_scoped(%Scope{} = scope, project),
    do: %Scope{scope | active_project: project, active_project_id: project.id}

  @doc """
  Which checkout a reader that named none is answered from.

  Answers must still come from one tree: blending every checkout
  over-satisfies (a file in one worktree reads as present everywhere).
  `project.default_working_copy_id` wins where set; otherwise the copy
  designated `main`. `nil` (no checkout) leaves the caller to blend.

  Here rather than in `Requirements`, so `Files` (`component_ids_present/1`)
  and `Preloader.files_vantage/1` share the one rule.
  """
  @spec reading_copy_id(Scope.t()) :: Ecto.UUID.t() | nil
  def reading_copy_id(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Repo.one(from p in Project, where: p.id == ^project_id, select: p.default_working_copy_id) ||
      Repo.one(from w in WorkingCopy, where: w.project_id == ^project_id and w.main, select: w.id)
  end

  def reading_copy_id(%Scope{}), do: nil

  @doc """
  Make this checkout the project's main working copy.

  Clears whichever copy held it first, because "at most one" is a database
  constraint here and setting the new one without clearing the old would be
  refused rather than silently producing two. In one transaction, so a failure
  leaves the project with the main copy it started with rather than none.

  Answers `{:error, :not_found}` for a copy on another project — the id arrives
  from a URL, and without the check any id would designate any project's copy.
  """
  @spec designate_main(Scope.t(), Ecto.UUID.t()) ::
          {:ok, WorkingCopy.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def designate_main(%Scope{active_project_id: project_id} = scope, working_copy_id)
      when is_binary(project_id) do
    Repo.transaction(fn -> designate_main_in_transaction(project_id, working_copy_id) end)
    |> case do
      {:ok, copy} ->
        broadcast_designated(scope, copy)

        # Designation moves graph inputs (which copy is `main`, so whose
        # preview fields are the running copy's). Announced here: the clearing
        # `update_all` never passes through `announce_graph_change/2`.
        GraphInputs.announce(project_id, "WorkingCopies", [], :project_wide)

        {:ok, copy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp designate_main_in_transaction(project_id, working_copy_id) do
    case Repo.get_by(WorkingCopy, id: working_copy_id, project_id: project_id) do
      nil ->
        Repo.rollback(:not_found)

      copy ->
        # Cleared first (the unique index allows one main per project), and
        # never the target: clearing it would leave the fetched struct saying
        # `main: true`, so the update below would be a no-op and the row would
        # end `false` while the caller was told it succeeded.
        from(w in WorkingCopy,
          where: w.project_id == ^project_id and w.main and w.id != ^working_copy_id
        )
        |> Repo.update_all(set: [main: false])

        case copy |> WorkingCopy.changeset(%{main: true}) |> Repo.update() do
          {:ok, designated} -> designated
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  # The page that designated it is not the only one showing which copy is main.
  defp broadcast_designated(%Scope{active_project_id: project_id}, copy) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "project:#{project_id}:working_copies",
      {:main_working_copy_designated, copy}
    )
  end

  @doc """
  What this copy's machine can do beyond the server's own tools.

  Written on every join: it is a fact about the machine right now.

  `:ok` either way: an older harness sends nothing, and a join must never be
  refused over its tool list.
  """
  @spec record_machine_tools(WorkingCopy.t(), [String.t()], map() | nil) :: :ok
  def record_machine_tools(%WorkingCopy{} = harness, names, docs \\ nil) when is_list(names) do
    harness
    |> WorkingCopy.changeset(machine_attrs(names, docs))
    |> Repo.update()

    :ok
  end

  # No docs sent (an older harness): the docs column is left alone, not blanked.
  defp machine_attrs(names, docs) when is_map(docs) and map_size(docs) > 0,
    do: %{machine_tools: names, machine_tool_docs: docs}

  defp machine_attrs(names, _docs), do: %{machine_tools: names}

  @doc """
  Why this machine's browser tool list is what it is.

  `"ready"`, `"absent"`, or `"unreachable"` with a reason — which the tool list
  alone cannot say (no browser and an unanswering one both list `[]`).

  `:ok` either way, as `record_machine_tools/3`.
  """
  @spec record_browser_status(WorkingCopy.t(), String.t(), String.t() | nil) :: :ok
  def record_browser_status(%WorkingCopy{} = harness, status, error) when is_binary(status) do
    harness
    |> WorkingCopy.changeset(%{browser_status: status, browser_error: error})
    |> Repo.update()

    :ok
  end

  def record_browser_status(_harness, _status, _error), do: :ok

  @doc "Record a legacy copy-scoped report on its default app instance."
  def record_preview_status(%WorkingCopy{} = copy, status) do
    scope = %Scope{active_project_id: copy.project_id}

    with {:ok, instance} <- AppInstances.ensure_default(scope, copy) do
      AppInstances.record_preview_status(scope, instance, status)
    end
  end

  @doc "Record a legacy copy-scoped runtime report on its default instance."
  def record_app_status(%WorkingCopy{} = copy, info) do
    scope = %Scope{active_project_id: copy.project_id}

    with {:ok, instance} <- AppInstances.ensure_default(scope, copy) do
      AppInstances.record_status(scope, instance, info)
    end
  end

  # No git state is stored here: the promote gate runs git itself.

  @doc """
  Record where a harness says its working copy is.

  Separate from `issue/3` because it is a different claim: `issue/3` answers
  "who are you", this answers "where are you", and only the first is identity.
  Called when a harness announces itself, so the root follows a checkout that
  moves without the id changing underneath its files.
  """
  @spec report_root(WorkingCopy.t(), String.t()) :: {:ok, WorkingCopy.t()} | {:error, term()}
  def report_root(%WorkingCopy{} = harness, root) when is_binary(root) do
    # And designated main if it is the project's only checkout. Here rather
    # than at insert: a row is not a checkout until it reports a root.
    # `harness.main or …` so a reconnect never clears its own designation.
    harness
    |> save(%{
      root: Path.expand(root),
      main: harness.main or only_checkout?(harness.project_id, harness.id)
    })
    |> announce_graph_change(harness)
  end

  @doc "Record the default instance's preview endpoint."
  def record_preview_url(%WorkingCopy{main: true} = copy, url) do
    scope = %Scope{active_project_id: copy.project_id}

    with {:ok, instance} <- AppInstances.ensure_default(scope, copy) do
      AppInstances.update(scope, instance, %{preview_url: url})
    end
  end

  def record_preview_url(%WorkingCopy{}, _url), do: {:error, :not_the_main_copy}

  @doc "Record preview routing on the default app instance."
  def record_preview_tunnel(%WorkingCopy{} = copy, attrs) do
    scope = %Scope{active_project_id: copy.project_id}

    with {:ok, instance} <- AppInstances.ensure_default(scope, copy) do
      AppInstances.record_preview_tunnel(scope, instance, attrs)
    end
  end

  def clear_preview_tunnel(%WorkingCopy{} = copy) do
    scope = %Scope{active_project_id: copy.project_id}

    with {:ok, instance} <- AppInstances.ensure_default(scope, copy) do
      AppInstances.clear_preview_tunnel(scope, instance)
    end
  end

  @doc "Whether any instance still references a shared tunnel."
  def tunnel_in_use?(tunnel_id) when is_binary(tunnel_id),
    do: Repo.exists?(from i in AppInstance, where: i.preview_tunnel_id == ^tunnel_id)

  @doc "The default workspace's instance preview, when available."
  def preview_url(%Scope{} = scope) do
    with %WorkingCopy{} = copy <- main(scope),
         %AppInstance{} = instance <- AppInstances.for_working_copy(scope, copy) do
      instance.preview_url
    else
      _ -> nil
    end
  end

  def preview_status(%Scope{} = scope) do
    with %WorkingCopy{} = copy <- main(scope),
         %AppInstance{} = instance <- AppInstances.for_working_copy(scope, copy) do
      instance.preview_status
    else
      _ -> nil
    end
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

  The operator's default view: it needs no configuration.
  """
  @spec list_harnesses(Scope.t()) :: [WorkingCopy.t()]
  def list_harnesses(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    # Device preloaded here so no caller renders `NotLoaded` as "no machine".
    Repo.all(
      from h in WorkingCopy,
        where: h.project_id == ^project_id,
        order_by: [desc_nulls_last: h.last_seen_at, desc: h.inserted_at],
        preload: [:device, :default_app_instance]
    )
  end

  @doc "The harness the operator sees unless they ask for another, or `nil`."
  @spec most_recent(Scope.t()) :: WorkingCopy.t() | nil
  def most_recent(%Scope{} = scope), do: scope |> list_harnesses() |> List.first()

  @doc """
  The scope a page showing files or problems should read with.

  Those rows are per working copy, so a project-wide scope would merge every
  checkout's. Defaults to the most recently active copy; a project with none
  keeps its project-wide scope.
  """
  @spec viewing(Scope.t() | nil) :: Scope.t() | nil
  def viewing(nil), do: nil

  def viewing(%Scope{active_project_id: nil} = scope), do: scope

  def viewing(%Scope{} = scope) do
    case most_recent(scope) do
      nil -> scope
      harness -> %{scope | active_working_copy_id: harness.id}
    end
  end

  # Scoped by project as well as id: a misconfigured checkout must not adopt
  # another project's copy.
  # The id to mint under: the one onboarding names, else the one the checkout
  # presented and no row anywhere holds. A restarted box whose row is gone
  # (a reset database, a deleted copy) comes back as the same working copy
  # instead of being issued a second id its own file will not adopt. An id
  # another project holds is never taken over: that one is minted fresh.
  defp presented_id(presented, opts) do
    with nil <- opts[:working_copy_id],
         {:ok, id} <- Ecto.UUID.cast(presented),
         false <- Repo.exists?(from(w in WorkingCopy, where: w.id == ^id)) do
      id
    else
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp existing(_project_id, nil), do: nil

  defp existing(project_id, working_copy_id) do
    case Ecto.UUID.cast(working_copy_id) do
      {:ok, id} -> Repo.get_by(WorkingCopy, id: id, project_id: project_id)
      :error -> nil
    end
  end

  # The device is written at mint, and a mint with none is refused: a seen row
  # must name a device (`seen_copies_are_on_a_machine`), and a device-less row
  # can never be recognised again, so the next onboard would duplicate it.
  # Both callers (harness join, onboarding) can say which machine they are.
  defp create(project_id, label, device, working_copy_id) do
    case device_id(device) do
      nil ->
        {:error, :no_device}

      id ->
        attrs = %{
          project_id: project_id,
          label: label,
          device_id: id,
          last_seen_at: now()
        }

        # The caller's id when it has one: onboarding writes the id into
        # `.cms_harness.json` first, and the row must hold the same value.
        %WorkingCopy{}
        |> WorkingCopy.changeset(maybe_put_id(attrs, working_copy_id))
        |> Repo.insert()
    end
  end

  defp maybe_put_id(attrs, id) when is_binary(id) and id != "", do: Map.put(attrs, :id, id)
  defp maybe_put_id(attrs, _id), do: attrs

  defp device_id(%Device{id: id}), do: id
  defp device_id(id) when is_binary(id) and id != "", do: id
  defp device_id(_device), do: nil

  # A project's *only* checkout is its main one. "Only", never "first": with
  # several checkouts and no main, "first to report" is a random pick. Where
  # there is a choice, a person makes it (`designate_main/2`).
  defp only_checkout?(project_id, working_copy_id) do
    not Repo.exists?(
      from w in WorkingCopy,
        where:
          w.project_id == ^project_id and w.id != ^working_copy_id and
            (w.main or not is_nil(w.root))
    )
  end

  # The label refreshes on join only while it is still the auto-generated one:
  # every connect sends the harness's default, which must never overwrite a
  # name a person chose with `relabel/3`.
  defp touch(harness, nil), do: save(harness, %{last_seen_at: now()})

  defp touch(harness, label) do
    if auto_label?(harness.label) do
      save(harness, %{last_seen_at: now(), label: label})
    else
      save(harness, %{last_seen_at: now()})
    end
  end

  # Whether a stored label is still nothing anybody chose — blank, or the
  # "the harness at <root> on <host>" shape `CmsHarness.Config.label/1`
  # falls back to. The same shape `display_name/1` recognizes to shorten for
  # display; here it is what tells a join there is nothing to protect.
  defp auto_label?(label) when is_binary(label) and label != "",
    do: Regex.match?(@auto_label_pattern, label)

  defp auto_label?(_label), do: true

  # The working-copy fields the requirement graph reads (the preloader's
  # working-copy gate inputs and `Promotion.running_copy_check/2`), and
  # nothing else.
  @graph_fields [:main]

  # Announced only when one of them actually moved: a health poll confirming
  # an unchanged status is not a change. See knowledge/promotion, "Lessons".
  defp announce_graph_change({:ok, updated} = result, %WorkingCopy{} = before) do
    if graph_inputs_moved?(before, updated),
      do: GraphInputs.announce(updated.project_id, "WorkingCopies", [], :project_wide)

    result
  end

  defp announce_graph_change(other, _harness), do: other

  defp graph_inputs_moved?(%WorkingCopy{} = before, %WorkingCopy{} = updated),
    do: Enum.any?(@graph_fields, &(Map.get(before, &1) != Map.get(updated, &1)))

  defp save(harness, attrs) do
    harness
    |> WorkingCopy.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Record that this harness is alive, because something it did just proved it.

  Split from `issue/3` ("who are you", once per connection): this is "you are
  still here", so `last_seen_at` stays current for a harness holding a stable
  channel. Also marks the copy's device alive. Nothing is deleted on this
  signal; it is shown to a person deciding.

  Best-effort: bookkeeping beside a request must never refuse it.
  """
  @spec mark_alive(WorkingCopy.t() | Ecto.UUID.t() | nil) :: :ok
  def mark_alive(%WorkingCopy{} = harness) do
    # `allow_stale: true`, not `save/2`'s plain update: a fresh join's own
    # `report_root/2` and this heartbeat can race within milliseconds over a
    # loopback connection, and a losing write here must not crash the channel
    # that sent it (see the moduledoc above) -- the row already reflects a
    # write at least as current as this one, which is all a heartbeat needs.
    harness
    |> WorkingCopy.changeset(%{last_seen_at: now()})
    |> Repo.update(allow_stale: true)

    # And its machine: otherwise a device's `last_seen_at` is only its boot
    # time. A machine with no working copy still has no signal of its own.
    CodeMySpec.Devices.mark_alive(harness.device_id)

    :ok
  end

  # No harness named: nothing to mark, and not an error.
  def mark_alive(nil), do: :ok

  def mark_alive(working_copy_id) when is_binary(working_copy_id) do
    case fetch(working_copy_id) do
      {:ok, harness} -> mark_alive(harness)
      {:error, _} -> :ok
    end
  end

  @doc """
  Give a working copy a name a person chose.

  A join never overwrites it (`touch/2`). Blank clears it rather than storing
  an empty string, so the display falls back to the root. `{:error,
  :cross_project}` for a copy on another project.
  """
  @spec relabel(Scope.t(), WorkingCopy.t(), String.t()) ::
          {:ok, WorkingCopy.t()} | {:error, Ecto.Changeset.t()}
  def relabel(
        %Scope{active_project_id: project_id},
        %WorkingCopy{project_id: project_id} = harness,
        label
      ) do
    harness
    |> WorkingCopy.changeset(%{label: normalize_label(label)})
    |> Repo.update()
  end

  def relabel(%Scope{}, %WorkingCopy{}, _label), do: {:error, :cross_project}

  @doc """
  The shortest thing that still identifies this copy.

  The auto-generated "the harness at <root> on <host>" label shortens to the
  root's last segment, the part that tells checkouts apart. A label a person
  chose is returned whole. No label falls back to the root's basename.
  """
  @spec display_name(WorkingCopy.t()) :: String.t()
  def display_name(%WorkingCopy{label: label} = harness) when is_binary(label) and label != "" do
    case Regex.run(~r{^the harness at\s+(\S+)}, label) do
      [_, path] -> Path.basename(path)
      _ -> label
    end
    |> fallback(harness)
  end

  def display_name(%WorkingCopy{root: root}) when is_binary(root) and root != "",
    do: Path.basename(root)

  def display_name(%WorkingCopy{}), do: "unnamed"

  defp fallback("", harness), do: display_name(%{harness | label: nil})
  defp fallback(name, _harness), do: name

  defp normalize_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_label(_label), do: nil

  @doc """
  The copies this device is carrying, as `id => root`.

  Answered to the device itself, on announce, so it knows what to look for.

  The server has to say: a harness only knows roots a hook has asked it to
  serve, which never includes a deleted worktree nobody works in. Unfiltered by
  project: the device answers for everything it carries in one pass.
  """
  @spec list_on_device(Device.t() | Ecto.UUID.t()) :: %{String.t() => String.t()}
  def list_on_device(%Device{id: device_id}), do: list_on_device(device_id)

  def list_on_device(device_id) when is_binary(device_id) do
    Repo.all(
      from w in WorkingCopy,
        where: w.device_id == ^device_id and not is_nil(w.root),
        select: {w.id, w.root}
    )
    |> Map.new()
  end

  def list_on_device(_device_id), do: %{}

  @doc """
  The projects whose app is serving from a copy on these devices, as
  `device_id => [project_id]`. A device with none is absent. A preview address
  belongs to the project, so that is what a caller builds one from.
  """
  @spec serving_projects_by_device([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [Ecto.UUID.t()]}
  def serving_projects_by_device(device_ids) when is_list(device_ids) do
    from(w in AppInstance,
      where: w.device_id in ^device_ids and w.status == "serving",
      distinct: true,
      select: {w.device_id, w.project_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The ids of every copy on each of these devices, as `device_id => [id]`. A
  device with no copies is absent.

  Every row, rootless or not: a device is an orphan only when nothing at all
  references it, since destroying one cascades its copies away.
  """
  @spec ids_by_device([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [Ecto.UUID.t()]}
  def ids_by_device(device_ids) when is_list(device_ids) do
    from(w in WorkingCopy, where: w.device_id in ^device_ids, select: {w.device_id, w.id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Record what a device can see of the copies attached to it.

  `observations` is `%{working_copy_id => present?}` — the harness's read of its
  own filesystem, one entry per copy it knows about. A copy it reports present
  has its warning cleared; one it reports missing is stamped, keeping whatever
  `path_missing_since` it already had so "missing since" means since the first
  time we were told, not since the last heartbeat.

  Scoped to `device_id`, a security boundary: the ids are input from a
  machine, which may speak only about rows that point at it.

  A copy it does not mention is untouched — silence is not absence.
  """
  @spec observe_paths(Device.t() | Ecto.UUID.t(), %{optional(String.t()) => boolean()}) :: :ok
  def observe_paths(%Device{id: device_id}, observations),
    do: observe_paths(device_id, observations)

  def observe_paths(device_id, observations)
      when is_binary(device_id) and map_size(observations) > 0 do
    {missing, present} =
      observations
      |> Enum.split_with(fn {_id, present?} -> present? == false end)
      |> then(fn {m, p} -> {ids(m), ids(p)} end)

    # Present clears unconditionally: the warning is about right now.
    Repo.update_all(
      from(w in WorkingCopy,
        where: w.device_id == ^device_id and w.id in ^present and not is_nil(w.path_missing_since)
      ),
      set: [path_missing_since: nil]
    )

    # Missing stamps only the first time, so "missing since" stays true.
    Repo.update_all(
      from(w in WorkingCopy,
        where: w.device_id == ^device_id and w.id in ^missing and is_nil(w.path_missing_since)
      ),
      set: [path_missing_since: now()]
    )

    :ok
  end

  def observe_paths(_device_id, _observations), do: :ok

  defp ids(pairs) do
    for {id, _present?} <- pairs, {:ok, uuid} = Ecto.UUID.cast(id), do: uuid
  end

  @doc """
  Attach a working copy to the machine it is on.

  Called on join, when the daemon says which device it is announcing from. A
  copy that moves machines — a repository cloned to a new laptop under the same
  id — re-attaches rather than being refused, because the copy's identity is its
  own and does not belong to the box.
  """
  @spec attach_device(WorkingCopy.t(), Device.t() | nil) ::
          {:ok, WorkingCopy.t()} | {:error, Ecto.Changeset.t()}
  def attach_device(%WorkingCopy{} = working_copy, nil), do: {:ok, working_copy}

  def attach_device(%WorkingCopy{device_id: id} = working_copy, %Device{id: id}),
    do: {:ok, working_copy}

  def attach_device(%WorkingCopy{} = working_copy, %Device{} = device) do
    working_copy
    |> WorkingCopy.changeset(%{device_id: device.id})
    |> Repo.update()
  end

  @doc "The device a working copy sits on, or `nil`."
  @spec device_of(Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  def device_of(nil), do: nil

  def device_of(working_copy_id) do
    Repo.one(
      from w in WorkingCopy,
        where: w.id == type(^working_copy_id, :binary_id),
        select: w.device_id
    )
  end

  @doc """
  Whether this copy's checkout has been reported gone.

  True once `observe_paths/2` has stamped `path_missing_since`.
  """
  @spec missing?(WorkingCopy.t()) :: boolean()
  def missing?(%WorkingCopy{path_missing_since: nil}), do: false
  def missing?(%WorkingCopy{}), do: true

  @doc """
  Delete a working copy's row. Its derived rows (files, problems, orphaned
  components) are the caller's to remove first, in the same transaction —
  `Staffing.offboard/2`, which sits above the contexts that own them.
  """
  @spec delete(Scope.t(), WorkingCopy.t()) :: :ok | {:error, :not_yours}
  def delete(%Scope{active_project_id: project_id}, %WorkingCopy{project_id: project_id, id: id})
      when is_binary(project_id) do
    Repo.delete_all(from w in WorkingCopy, where: w.id == ^id)
    :ok
  end

  def delete(%Scope{}, %WorkingCopy{}), do: {:error, :not_yours}

  @doc """
  Tell the machine serving `working_copy_id` that the copy was offboarded, so
  it drops the channel and watchers. Call after the delete commits.
  """
  @spec released(Ecto.UUID.t()) :: :ok
  def released(working_copy_id) do
    tell_the_machine(working_copy_id)
    :ok
  end

  # Without this an offboarded copy stays served on its machine (joined,
  # scanning a gone directory) until a restart. Best-effort and
  # fire-and-forget, after the transaction: the machine may be off, and an
  # offboard must never fail or hang on it.
  defp tell_the_machine(working_copy_id) do
    case HarnessRegistry.executor_holder(working_copy_id) do
      {:ok, pid, _instance} -> send(pid, {:offboarded, working_copy_id})
      _ -> :ok
    end
  end

  defp now, do: DateTime.utc_now()
end
