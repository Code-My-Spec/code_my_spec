defmodule CodeMySpec.WorkingCopies do
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

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.WorkingCopies.WorkingCopy
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
  @spec issue(Scope.t(), String.t() | nil, keyword()) :: {:ok, WorkingCopy.t()} | {:error, term()}
  def issue(%Scope{active_project_id: project_id}, working_copy_id, opts \\ [])
      when is_binary(project_id) do
    label = Keyword.get(opts, :label)

    case existing(project_id, working_copy_id) do
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

  Takes no scope, and that is the point: the id *is* the identity, so resolving
  it must not depend on already knowing which project or directory is involved.
  Every other lookup here is scoped by project because it starts from a
  question about a project; this one starts from a harness announcing itself.

  Used to answer a hook. A hook that names an id gets that harness's project
  and root, rather than the old routing, which took the path the hook announced
  and walked up to the nearest `mix.exs` — so one session resolved to different
  roots depending on the subdirectory it fired from, and a checkout nested
  under another resolved to the outer one.

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
  Point a scope at a harness: which checkout, where it is, and how to reach it.

  All three, together, because the third is the one that gets forgotten.
  `HarnessProjectChannel` set every field and MCP requests set only
  `active_working_copy_id` — so a tool invoked over `/mcp/harness` knew exactly which
  working copy it was talking about and had no way to read or write a byte of
  it. `regenerate_proposal` surfaced it by trying: the transport is fine, the
  harness implements every op, and the call failed with `:no_environment`
  because the scope carried none.

  `cwd` is the harness's own recorded root rather than anything the request
  said. A request that could name its own directory would be back to resolving
  a working copy by path, which is what addressing by id replaced.
  """
  @spec put_scope(Scope.t(), WorkingCopy.t()) :: Scope.t()
  def put_scope(%Scope{} = scope, %WorkingCopy{} = harness) do
    %{
      scope
      | active_working_copy_id: harness.id,
        cwd: harness.root || scope.cwd,
        environment: Environment.new(:harness, harness.root, ref: %{"harness_id" => harness.id})
    }
  end

  @doc """
  Record where a harness says its working copy is.

  Separate from `issue/3` because it is a different claim: `issue/3` answers
  "who are you", this answers "where are you", and only the first is identity.
  Called when a harness announces itself, so the root follows a checkout that
  moves without the id changing underneath its files.
  """
  @spec report_root(WorkingCopy.t(), String.t()) :: {:ok, WorkingCopy.t()} | {:error, term()}
  def report_root(%WorkingCopy{} = harness, root) when is_binary(root) do
    save(harness, %{root: Path.expand(root)})
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
  @spec list_harnesses(Scope.t()) :: [WorkingCopy.t()]
  def list_harnesses(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    # The device comes with it. Every caller that lists copies wants to say
    # which machine each is on — a path is not identity precisely because two
    # machines can share one — and preloading here rather than at each call site
    # keeps one of them from quietly rendering `%Ecto.Association.NotLoaded{}`
    # as "no machine", which is a different and wrong claim.
    Repo.all(
      from h in WorkingCopy,
        where: h.project_id == ^project_id,
        order_by: [desc_nulls_last: h.last_seen_at, desc: h.inserted_at],
        preload: [:device]
    )
  end

  @doc "The harness the operator sees unless they ask for another, or `nil`."
  @spec most_recent(Scope.t()) :: WorkingCopy.t() | nil
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
      harness -> %{scope | active_working_copy_id: harness.id}
    end
  end

  # Scoped by project as well as id: an id from one project must not resolve
  # against another's, or a misconfigured checkout would silently adopt a
  # harness belonging to a project it has nothing to do with.
  defp existing(_project_id, nil), do: nil

  defp existing(project_id, working_copy_id) do
    case Ecto.UUID.cast(working_copy_id) do
      {:ok, id} -> Repo.get_by(WorkingCopy, id: id, project_id: project_id)
      :error -> nil
    end
  end

  defp create(project_id, label) do
    %WorkingCopy{}
    |> WorkingCopy.changeset(%{project_id: project_id, label: label, last_seen_at: now()})
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
    |> WorkingCopy.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Record that this harness is alive, because something it did just proved it.

  Split from `issue/3`, which answers "who are you" and happens once per
  connection. This answers "you are still here", and the difference is what
  `reclaim_quiet/1` reads.

  Before this existed, `last_seen_at` was written only on channel join and on
  onboarding — so it recorded when a harness last *connected*, and a harness
  holding a stable channel never reconnects. The signal therefore got staler the
  longer an agent worked without interruption. Measured on this project: two
  harnesses whose agents were mid-session, scanning and answering hooks
  continuously, read 2:21 and 2:25 idle against a 2 hour window, having only
  ever run down. The next sync from any third agent would have deleted both
  agents' state underneath them — the exact failure the reclaim was written to
  avoid, arriving through the liveness signal instead of through row age.

  Best-effort on purpose. This is bookkeeping on the side of a request that has
  real work to do, and a harness that cannot be marked alive is not a reason to
  refuse its hook.
  """
  @spec mark_alive(WorkingCopy.t() | Ecto.UUID.t() | nil) :: :ok
  def mark_alive(%WorkingCopy{} = harness) do
    save(harness, %{last_seen_at: now()})

    # And the machine it is on. A checkout proving it is alive is also its box
    # proving it is alive, and without this a device's `last_seen_at` is only
    # ever its boot time — every machine reads "Last seen" two minutes in, with
    # its harness connected and serving.
    #
    # A machine with no working copy at all still has no signal of its own.
    # That gap is real and named rather than papered over: this covers the case
    # that exists today, where a harness serves at least one checkout.
    CodeMySpec.Devices.mark_alive(harness.device_id)

    :ok
  end

  # A caller that names no harness has nothing to mark, and that is a normal
  # state rather than an error: plenty of writers legitimately have no checkout
  # to point at. Raising here would make bookkeeping on the side of a request
  # able to fail the request.
  def mark_alive(nil), do: :ok

  def mark_alive(working_copy_id) when is_binary(working_copy_id) do
    case fetch(working_copy_id) do
      {:ok, harness} -> mark_alive(harness)
      {:error, _} -> :ok
    end
  end

  @doc """
  Give a working copy a name a person chose.

  `issue/3` has always accepted a label and nothing ever set one, so every copy
  rendered as its root — and two checkouts of one project differ in a single
  directory somewhere deep in a path. That is not a distinction anybody reads
  correctly at speed, and it is the condition under which somebody acts on the
  wrong row.

  Blank clears it rather than storing an empty string, so the display falls back
  to the root instead of showing nothing.
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

  A harness that names itself gets `CMS_HARNESS_LABEL`; one that does not gets
  "the harness at <root> on <host>" from `CmsHarness.Config`. That default is a
  sentence containing a path, so it reads as a name and identifies like a path —
  90 characters where two checkouts differ in one directory. The distinguishing
  part is the root's last segment, which is what this returns.

  A label a person actually chose is returned whole: it is short because they
  made it short, and truncating somebody's chosen name is a different kind of
  wrong from truncating a generated one.

  Extracted from `HarnessPicker.short_label/1`, which had this logic to itself
  while every other surface rendered the full sentence.
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
  Reclaim the derived state of every agent on this project that has gone quiet.

  Files and problems, unconditionally. Components only where they have no files
  **and** no story link.

  ## Why derived state and not the row

  Problems are properties of the codebase, not of the database: an agent that
  comes back runs analysis and produces them again. Files are the same — the
  working copy is the truth and the rows are a projection. Keeping either across
  an absence preserves nothing and blocks other people's gates meanwhile.

  The harness row survives, and that is what makes the rest simple. Identity lives
  in `.cms_harness.json` in the checkout, so a returning agent presents the id it
  always had and resumes. Deleting the row would leave the file naming something
  that does not exist, and the adjacent case is already observable: re-onboarding a
  root whose identity file was removed issues a *third* id rather than resuming, so
  every offboard/return cycle would leak one.

  ## Why liveness comes from the agent

  `last_seen_at`, never the age of the rows an agent produced. Rows update on
  scans, and scans happen on hooks rather than on activity — this working copy went
  unswept for three and a half hours while being actively worked, because the
  harness was busy holding others. A rule keyed on row age reclaims someone
  mid-session.

  That only holds while `last_seen_at` means "last proof of life". It originally
  meant "last connected", which is worse — see `mark_alive/1`, which is what
  keeps the two the same thing.

  `last_seen_at` is `utc_datetime_usec`, so comparing it against `DateTime.utc_now/0`
  is correct without a workaround. `updated_at` is `timestamp without time zone`
  holding UTC, and comparing *that* against `now()` renders one side local: every
  live agent reads as hours idle, an expiry never fires here and fires wrongly
  elsewhere.

  ## Never the caller

  The scope's own harness is excluded. It is live by definition — it is the one
  asking — and a sweep that inherited the harness scoping every other operation
  here uses would sweep only itself, find nothing, and reclaim nothing forever
  while looking correct.
  """
  @spec reclaim_quiet(Scope.t()) :: {:ok, %{harnesses: integer(), components: integer()}}
  def reclaim_quiet(%Scope{active_project_id: project_id} = scope)
      when is_binary(project_id) do
    cutoff = DateTime.add(now(), -idle_seconds(scope), :second)

    quiet_ids =
      Repo.all(
        from h in WorkingCopy,
          where: h.project_id == ^project_id,
          # `nil` is never quiet. The project's default harness — the row
          # unnamed writers share — never joins, so its `last_seen_at` stays nil
          # by design, and that is what distinguishes it from a checkout in the
          # operator's list. Treating nil as "gone" reclaimed it on every sync,
          # in every project, and took ten other stories' spex down with it.
          where: not is_nil(h.last_seen_at) and h.last_seen_at < ^cutoff,
          where: h.id != ^(scope.active_working_copy_id || Ecto.UUID.generate()),
          select: h.id
      )

    reclaim_harnesses(scope, quiet_ids ++ abandoned_ids(scope))
  end

  def reclaim_quiet(_scope), do: {:ok, %{harnesses: 0, components: 0}}

  # Defence in depth against a file row naming a harness that does not exist.
  # It cannot currently fire, and the reason it was written is not the reason to
  # keep it.
  #
  # `8c75e2df` recorded this as measured — "two harnesses existed and every file
  # belonged to a third id" — and that measurement cannot have meant what it
  # appeared to. `files_working_copy_id_fkey` has referenced `harnesses(id)` since
  # `20260807210000`, and `exqlite` defaults `foreign_keys: :on`, so the
  # constraint is enforced on both adapters. Checked on the live server: 0
  # orphaned or cross-project rows out of 8,063 files carrying a working_copy_id.
  # The likeliest reading is the report's own wording — the id appeared in no
  # harness row *for that project*, which is a different claim, and spex
  # fixtures mint a harness per `full_scope_fixture` call.
  #
  # Kept anyway, because the two schemas are not equally strong. On SQLite the
  # NOT NULL and the `:delete_all` flip were never mirrored — `ALTER COLUMN`
  # does not exist there, and rebuilding `files` was judged too expensive — so
  # that deployment holds a nullable column with `on_delete: :nilify_all`. Its
  # own migration says the constraint is "the application's rather than the
  # database's". One cheap query is a reasonable price for the case where that
  # judgement is revisited.
  #
  # What it does *not* cover, deliberately, because SQL says so: a row whose
  # `working_copy_id` is NULL. `NULL NOT IN (…)` is NULL, never true, so those rows
  # are invisible here. `20260807220000` deleted the existing ones and argues
  # every writer now names its working copy.
  #
  # Excludes the caller, like the aged set: a live agent writing rows faster than
  # its harness is created must not sweep its own work.
  defp abandoned_ids(%Scope{active_project_id: project_id} = scope) do
    Repo.all(
      from f in CodeMySpec.Files.File,
        where: f.project_id == ^project_id,
        where: f.working_copy_id not in subquery(from h in WorkingCopy, select: h.id),
        where: f.working_copy_id != ^(scope.active_working_copy_id || Ecto.UUID.generate()),
        distinct: true,
        select: f.working_copy_id
    )
  end

  defp reclaim_harnesses(_scope, []), do: {:ok, %{harnesses: 0, components: 0}}

  defp reclaim_harnesses(%Scope{active_project_id: project_id}, quiet_ids) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from f in CodeMySpec.Files.File,
          where: f.project_id == ^project_id and f.working_copy_id in ^quiet_ids
      )

      Repo.delete_all(
        from p in CodeMySpec.Problems.Problem,
          where: p.project_id == ^project_id and p.working_copy_id in ^quiet_ids
      )

      # Two plain subqueries rather than correlated `exists`. The component set is
      # small and this is legible: anything a file or a story points at is kept,
      # everything else on the project goes.
      referenced_by_files =
        from f in CodeMySpec.Files.File,
          where: f.project_id == ^project_id and not is_nil(f.component_id),
          select: f.component_id

      referenced_by_stories =
        from s in CodeMySpec.Stories.Story,
          where: s.project_id == ^project_id and not is_nil(s.component_id),
          select: s.component_id

      keep =
        (Repo.all(referenced_by_files) ++ Repo.all(referenced_by_stories))
        |> Enum.uniq()

      {components, _} =
        Repo.delete_all(
          from c in CodeMySpec.Components.Component,
            where: c.project_id == ^project_id and c.id not in ^keep
        )

      %{harnesses: length(quiet_ids), components: components}
    end)
    |> case do
      {:ok, counts} ->
        {:ok, counts}

      {:error, reason} ->
        # Loud, never swallowed. A reclaim that fails quietly leaves the orphan
        # in place and reports success, which is indistinguishable from a project
        # that had nothing to reclaim — and that is the failure this story exists
        # to remove, reproduced inside its own fix.
        raise "reclaim_quiet failed for project #{inspect(reason)}"
    end
  end

  defp idle_seconds(%Scope{} = scope) do
    hours =
      case CodeMySpec.Configurations.get(scope) do
        %{working_copy_idle_hours: hours} when is_integer(hours) -> hours
        _ -> 2
      end

    hours * 3600
  end

  defp now, do: DateTime.utc_now()
end
