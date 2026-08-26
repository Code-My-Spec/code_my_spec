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

  alias CodeMySpec.Devices.Device
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
      nil -> recognise_or_create(project_id, label, opts)
      harness -> touch(harness, label)
    end
  end

  # Before minting, ask whether this checkout is already known.
  #
  # A copy that presents no id — or one this project does not recognise — used
  # to become a new row every time, and a checkout does that on every join where
  # its `.cms_harness.json` could not be read. Measured on this project: 52 rows
  # for one worktree, five of them minted inside a single second, and only one
  # of the 52 carrying any files. Everything keyed on the working copy then
  # splits across identities that describe the same directory.
  #
  # `device_id` and `root` together, never root alone. Two machines share a path
  # constantly — every container at `/workspace/app` — which is why root is
  # recorded as reported rather than identifying, and why story 1020's criterion
  # 2843 exists. The device is what that criterion established as the
  # disambiguator, and one directory on one machine is one checkout.
  #
  # Both or neither: without a device this cannot tell two machines apart, and
  # guessing would merge somebody else's checkout into this one. A join that
  # carries no device still mints, which is the pre-device behaviour and is
  # correct for a harness too old to say.
  defp recognise_or_create(project_id, label, opts) do
    case recognised(project_id, opts[:device], opts[:root]) do
      nil -> create(project_id, label)
      harness -> touch(harness, label)
    end
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
        # The oldest is the one everything else already points at. A newer
        # duplicate exists precisely because this lookup was missing, so
        # adopting it would strand the files, problems and verdicts written
        # under the original.
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
  The checkout this project's own agent runs in, or nil.

  Nil is an ordinary answer rather than a fault: a project nobody has onboarded
  a checkout for has no main copy, and the surfaces that need one say so rather
  than inventing one. Guessing is the thing this whole idea exists to avoid.
  """
  @spec main(Scope.t()) :: WorkingCopy.t() | nil
  def main(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Repo.one(from w in WorkingCopy, where: w.project_id == ^project_id and w.main)
  end

  def main(%Scope{}), do: nil

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
    Repo.transaction(fn ->
      case Repo.get_by(WorkingCopy, id: working_copy_id, project_id: project_id) do
        nil ->
          Repo.rollback(:not_found)

        copy ->
          # Cleared first. The index permits one row per project with `main`
          # true, so writing the new one while the old still holds it is a
          # constraint violation rather than a replacement.
          from(w in WorkingCopy, where: w.project_id == ^project_id and w.main)
          |> Repo.update_all(set: [main: false])

          case copy |> WorkingCopy.changeset(%{main: true}) |> Repo.update() do
            {:ok, designated} -> designated
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, copy} ->
        # The agent goes where the designation goes. A project whose main copy
        # is one checkout and whose main agent is running in another satisfies
        # nobody: the page names one place and the work happens in the other.
        _ = CodeMySpec.Agents.move_main_agent(scope, copy)
        broadcast_designated(scope, copy)
        {:ok, copy}

      {:error, reason} ->
        {:error, reason}
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
  Record where a harness says its working copy is.

  Separate from `issue/3` because it is a different claim: `issue/3` answers
  "who are you", this answers "where are you", and only the first is identity.
  Called when a harness announces itself, so the root follows a checkout that
  moves without the id changing underneath its files.
  """
  @spec report_root(WorkingCopy.t(), String.t()) :: {:ok, WorkingCopy.t()} | {:error, term()}
  def report_root(%WorkingCopy{} = harness, root) when is_binary(root) do
    # And designated, if this is the project's first checkout.
    #
    # Here rather than at insert, because a row is not a checkout until it says
    # where it is: `issue/3` mints before any root is known, and fixtures,
    # `ensure_default/1`'s nil-object row and a join that has not announced yet
    # are all rows that will never have one.
    #
    # Designating one of those is the quiet failure criterion 2906 is named
    # after. The project reports somewhere for its agent to run, an agent is
    # started there with `working_copy: nil`, the machine refuses it, and the
    # page says "getting ready" about a checkout that does not exist — with no
    # error anywhere for anybody to act on.
    #
    # `harness.main or …` rather than the check alone: a copy that already holds
    # the designation makes `first_copy?/1` false, so writing the bare result
    # back would clear the main copy on its own reconnect.
    save(harness, %{
      root: Path.expand(root),
      main: harness.main or only_checkout?(harness.project_id, harness.id)
    })
  end

  @doc """
  Record where this checkout's preview answers.

  Only for the copy the project designated. The preview runs where the project
  runs, and every worktree can run the app — so an address on a sibling checkout
  is a second answer to a question that has one, and the panel would have to
  pick between them with nothing to pick on.

  Refused rather than ignored: onboarding a worktree with a preview URL is a
  person believing they have set the project's preview, and silence there is the
  failure this returns instead.
  """
  @spec record_preview_url(WorkingCopy.t(), String.t() | nil) ::
          {:ok, WorkingCopy.t()} | {:error, :not_the_main_copy} | {:error, term()}
  def record_preview_url(%WorkingCopy{main: true} = harness, url) do
    save(harness, %{preview_url: url})
  end

  def record_preview_url(%WorkingCopy{}, _url), do: {:error, :not_the_main_copy}

  @doc """
  Where this project's preview answers, or nothing.

  Nothing is the ordinary state — a project whose main checkout was onboarded
  before this existed, or one with no main checkout at all. The panel says so
  rather than showing an empty frame.
  """
  @spec preview_url(Scope.t()) :: String.t() | nil
  def preview_url(%Scope{} = scope) do
    case main(scope) do
      %WorkingCopy{preview_url: url} when is_binary(url) and url != "" -> url
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
    |> WorkingCopy.changeset(%{
      project_id: project_id,
      label: label,
      last_seen_at: now()
    })
    |> Repo.insert()
  end

  # A project's *only* checkout is its main one.
  #
  # Not the inference `designate_main/2` exists to rule out: that rule is about
  # six checkouts of one repository, where a path, a label and a last-seen time
  # each pick a different wrong one. With one there is nothing to choose
  # between, and leaving it undesignated leaves a project made by `cms.new`
  # with a checkout, no main copy and no agent — a state nobody can act on and
  # nothing asked for.
  #
  # "Only" and not "first", because the two differ precisely where it matters.
  # Keying on "no main copy yet" designates whatever reports a root while that
  # is true — which on a project that already has six checkouts is whichever
  # harness reconnects first, and that is the guess this rule was written to
  # avoid. It is not hypothetical: this project has six, and turning the
  # feature on would have designated one of them at random.
  #
  # So where there is a choice to make, nothing makes it. `designate_main/2` is
  # how a person does, and the page offers it on every copy that is not already
  # the main one.
  defp only_checkout?(project_id, working_copy_id) do
    not Repo.exists?(
      from w in WorkingCopy,
        where:
          w.project_id == ^project_id and w.id != ^working_copy_id and
            (w.main or not is_nil(w.root))
    )
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
  connection. This answers "you are still here", and the difference is what the
  operator's list reads to say how long ago a copy was last heard from.

  Before this existed, `last_seen_at` was written only on channel join and on
  onboarding — so it recorded when a harness last *connected*, and a harness
  holding a stable channel never reconnects. The signal therefore got staler the
  longer an agent worked without interruption. Measured on this project: two
  harnesses whose agents were mid-session, scanning and answering hooks
  continuously, read 2:21 and 2:25 idle against a 2 hour window, having only
  ever run down — and at the time that window decided what got deleted, so both
  were one sync away from losing their state to a third agent.

  Nothing is deleted on this signal any more; `offboard/2` is an act somebody
  takes and `observe_paths/2` is what warns them. But the number is still shown
  to a person who is deciding, so it still has to mean what it says.

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
  The copies this device is carrying, as `id => root`.

  Answered to the device itself, on announce, so it knows what to look for.

  ## Why the server has to say

  A harness builds its own list from the roots it has been asked to serve since
  it started, and it is asked by a hook arriving. So a copy nobody works in
  again is never on that list — and a copy nobody works in again is precisely
  the one whose worktree has been deleted. The feature could not see its own
  case, for as long as the harness was the only one keeping track.

  Unfiltered by project on purpose. A device carries checkouts of whatever it
  carries, and the reporter answers for all of them in one pass; scoping this to
  a project would need the device to know which projects it is on before it
  could ask, which is the wrong way round.
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
  Record what a device can see of the copies attached to it.

  `observations` is `%{working_copy_id => present?}` — the harness's read of its
  own filesystem, one entry per copy it knows about. A copy it reports present
  has its warning cleared; one it reports missing is stamped, keeping whatever
  `path_missing_since` it already had so "missing since" means since the first
  time we were told, not since the last heartbeat.

  ## Only about its own copies

  Scoped to `device_id`, and that is the security boundary rather than a tidiness
  one. The ids arrive from a machine, so they are input: without it, a device
  could report somebody else's checkout missing by naming its id, and the
  operator would be looking at a warning about a laptop that is perfectly fine.

  It is also what makes two copies at the same path on two machines behave.
  Paths collide constantly — every container at `/workspace/app` — and the
  answer is that a device speaks only about rows that point at it.

  ## A copy it does not mention is untouched

  Not "absent, therefore gone". That is the whole inversion this replaced: the
  old rule read silence as death and was one sync away from deleting two
  mid-session agents' state, because the signal it trusted went stale while they
  worked. A harness that has never been asked about a copy, or that is offline
  entirely, says nothing about it, and nothing is what that means.
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

    # Present clears unconditionally: a path that came back is back, and the
    # warning is about right now rather than about what once happened.
    Repo.update_all(
      from(w in WorkingCopy,
        where: w.device_id == ^device_id and w.id in ^present and not is_nil(w.path_missing_since)
      ),
      set: [path_missing_since: nil]
    )

    # Missing stamps only the first time. Re-stamping on every heartbeat would
    # make a copy that vanished last week read as "missing for 30 seconds", and
    # how long it has been gone is the only thing that tells an operator whether
    # this was them.
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
  Whether this copy's checkout has been reported gone.

  A predicate rather than a field read at every call site, because the nil case
  means two things and only one reading of it is ever right here.
  """
  @spec missing?(WorkingCopy.t()) :: boolean()
  def missing?(%WorkingCopy{path_missing_since: nil}), do: false
  def missing?(%WorkingCopy{}), do: true

  @doc """
  Remove a working copy and everything derived from it.

  Files and problems unconditionally; components only where they have no files
  **and** no story link. Then the row itself.

  ## Why this is an act and not a sweep

  It used to happen on its own, to any copy quiet longer than a configured
  window, riding on whichever agent next synced components. That model is gone.
  It could not tell a checkout that had been deleted from an agent that was
  simply busy, because the only thing it had to go on was elapsed time — and it
  got that wrong in the expensive direction, reading two mid-session harnesses
  as 2:21 and 2:25 idle against a two hour window.

  What replaced it: the harness says whether the path is still there, that shows
  up as a warning, and a person decides. The cost is that an orphan blocks until
  somebody clears it. That is the better failure — a visible thing waiting for a
  click, rather than an invisible one deleting a working agent's state.

  ## Why the row goes too

  The old rule kept it, on the argument that identity lives in
  `.cms_harness.json` so a returning agent presents the id it always had. A
  removed checkout took that file with it, so there is nothing left to present
  and nothing to come back to. A copy that reappears at the same path is
  onboarded, which mints a new id — see 891.

  ## What it never does

  Touch the checkout. The row is ours and the directory is not, and a server
  that deletes somebody's files because they clicked a button in a list is not a
  trade anyone asked for. Offboarding a copy whose checkout still exists leaves
  it exactly where it is, config file and all — it will simply not be recognised
  until it onboards again.
  """
  @spec offboard(Scope.t(), WorkingCopy.t()) ::
          {:ok, %{files: integer(), problems: integer(), components: integer()}}
          | {:error, :not_yours}
  def offboard(%Scope{active_project_id: project_id} = scope, %WorkingCopy{
        project_id: project_id,
        id: id
      })
      when is_binary(project_id) do
    _ = scope

    Repo.transaction(fn ->
      {files, _} =
        Repo.delete_all(
          from f in CodeMySpec.Files.File,
            where: f.project_id == ^project_id and f.working_copy_id == ^id
        )

      {problems, _} =
        Repo.delete_all(
          from p in CodeMySpec.Problems.Problem,
            where: p.project_id == ^project_id and p.working_copy_id == ^id
        )

      components = reclaim_orphan_components(project_id)

      Repo.delete_all(from w in WorkingCopy, where: w.id == ^id)

      %{files: files, problems: problems, components: components}
    end)
    |> case do
      {:ok, counts} ->
        {:ok, counts}

      {:error, reason} ->
        # Loud, never swallowed. An offboard that fails quietly leaves the orphan
        # in place and reports success, which is indistinguishable from one that
        # had nothing to remove — and that is the failure this story exists to
        # remove, reproduced inside its own fix.
        raise "offboard failed for working copy #{id}: #{inspect(reason)}"
    end
  end

  def offboard(%Scope{}, %WorkingCopy{}), do: {:error, :not_yours}

  # Two plain subqueries rather than correlated `exists`. The component set is
  # small and this is legible: anything a file or a story points at is kept,
  # everything else on the project goes.
  #
  # The story link is the one that matters. A component somebody wrote a story
  # against is authored work, and spending it to clear derived rows would make
  # this destructive in a way no warning covers.
  defp reclaim_orphan_components(project_id) do
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

    components
  end

  defp now, do: DateTime.utc_now()
end
