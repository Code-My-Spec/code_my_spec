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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Components,
      CodeMySpec.Devices,
      CodeMySpec.Encrypted.Binary,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users
    ],
    exports: :all

  import Ecto.Query, warn: false

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Analysis
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  # `CmsHarness.Config.label/1`'s fallback shape — "the harness at <root> on
  # <host>" — sent by a harness that nobody has named. `display_name/1` below
  # matches the same shape (its own regex; it only needs the path, not the
  # host) to shorten it for display. `touch/2` uses this one to tell that
  # shape apart from a name a person actually chose.
  @auto_label_pattern ~r{^the harness at\s+\S+ on\s+\S+}

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

    with :ok <- refuse_metadata_dir(opts[:root]) do
      case existing(project_id, working_copy_id) do
        nil -> recognise_or_create(project_id, label, opts)
        harness -> touch(harness, label)
      end
    end
  end

  # A checkout's own `.code_my_spec/` is not a checkout.
  #
  # One registered itself as a second working copy on this project and
  # reconnected for days. Analysis routed to it — it is a legitimate row on the
  # right project — and every spex run died as `(Mix) The task "spex" could not
  # be found`, because there is no `mix.exs` a level down. The real root's
  # staleness never cleared, so a stop hook reported spex files as "stale, no
  # rerun running" long after they were verified green, with nothing an agent
  # could do to force a correctly-routed run. Issue 49e8340e.
  #
  # The harness diagnosed it out loud and carried on: "nothing to watch under
  # …/.code_my_spec — no lib/, test/ or .code_my_spec/. Is this the right
  # working directory?" A self-diagnosis nothing acts on is a log line.
  #
  # Refused rather than normalised to the parent, because a caller offering this
  # root is confused about what it is holding and quietly registering it as
  # something else would hide that. Refused *server*-side because every client
  # reaches here, including a harness too old to carry a client-side guard.
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
      nil -> create(project_id, label, opts[:device], opts[:working_copy_id])
      harness -> touch(harness, label)
    end
  end

  @doc """
  The checkout at this root on the caller's own machine, or `nil`.

  Naming a root is how every caller outside a harness names a checkout — the MCP
  `start_agent` tool passes one and no id — and until this existed the id was
  filled in from the caller's scope instead. That put the agent's row on the
  caller's copy however far away the named root was, and made the main-copy guard
  fire on starts that named somewhere else entirely.

  Scoped to the caller's device on purpose: one root can exist on two machines,
  `/workspace/app` is every container's default, and a lookup by root alone would
  have to guess between them. A caller naming a path means the path on the box
  they are on.
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
    Repo.transaction(fn -> designate_main_in_transaction(project_id, working_copy_id) end)
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

  defp designate_main_in_transaction(project_id, working_copy_id) do
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

  Written on every join rather than once, because it is a fact about the machine
  right now: a browser installed since the last connect is one an agent started
  after this can use, and one uninstalled is one it must not be offered.

  `:ok` either way. A machine that could not say is not a machine that failed —
  an older harness sends nothing at all, and refusing its join over a browser
  would take the checkout down for the tools it does have.
  """
  @spec record_machine_tools(WorkingCopy.t(), [String.t()], map() | nil) :: :ok
  def record_machine_tools(%WorkingCopy{} = harness, names, docs \\ nil) when is_list(names) do
    harness
    |> WorkingCopy.changeset(machine_attrs(names, docs))
    |> Repo.update()

    :ok
  end

  # A harness too old to send documentation still sends its names, and the
  # column is left alone rather than blanked: what is recorded is one join stale
  # and better than nothing, which is what overwriting it with `nil` would leave.
  defp machine_attrs(names, docs) when is_map(docs) and map_size(docs) > 0,
    do: %{machine_tools: names, machine_tool_docs: docs}

  defp machine_attrs(names, _docs), do: %{machine_tools: names}

  @doc """
  Why this machine's browser tool list is what it is.

  `"ready"`, `"absent"`, or `"unreachable"` with a reason. The distinction the
  list alone cannot make: a machine with no vibium and one whose vibium would
  not answer both report `[]`, and only the second is something an operator can
  act on.

  `:ok` either way, on the same reasoning as `record_machine_tools/2` above — an
  older harness sends nothing, and that is a harness, not a failure.
  """
  @spec record_browser_status(WorkingCopy.t(), String.t(), String.t() | nil) :: :ok
  def record_browser_status(%WorkingCopy{} = harness, status, error) when is_binary(status) do
    harness
    |> WorkingCopy.changeset(%{browser_status: status, browser_error: error})
    |> Repo.update()

    :ok
  end

  def record_browser_status(_harness, _status, _error), do: :ok

  @doc """
  Record whether this checkout is in sync with main and whether its tree is
  clean.

  Reported by the machine that holds the disk, on every sync, because the server
  has no `git` to run against a harness-served checkout and a requirement graph
  computed inside the channel process cannot ask the channel. Same shape as
  `Sync.report_head_commit/2`, which already runs git in the real checkout for
  the same reason.

  Nothing is derived here. Three numbers arrive and three numbers are stored, so
  a gate reading them is reading what the checkout actually said rather than an
  interpretation made on the way in.
  """
  @spec record_git_state(WorkingCopy.t(), map()) :: {:ok, WorkingCopy.t()} | {:error, term()}
  def record_git_state(%WorkingCopy{} = harness, %{} = state) do
    save(harness, %{
      commits_ahead_of_main: state[:ahead] || state["ahead"],
      commits_behind_main: state[:behind] || state["behind"],
      tree_dirty: state[:dirty] || state["dirty"],
      git_state_at: DateTime.utc_now()
    })
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
  Record the tunnel that carries this copy's preview, and the address it
  carries it to.

  One write rather than three. The address is only reachable *because* of the
  tunnel, so a copy holding an address with no credential — or a credential
  with no address — describes a preview that cannot work, and the panel would
  frame it anyway. Saving them together means that state is unreachable rather
  than merely unlikely.

  Refused on a copy that is not the main one, for the same reason
  `record_preview_url/2` is: provisioning a tunnel for a worktree spends a real
  Cloudflare record on an address the panel will never read.
  """
  @spec record_preview_tunnel(WorkingCopy.t(), map()) ::
          {:ok, WorkingCopy.t()} | {:error, :not_the_main_copy} | {:error, term()}
  def record_preview_tunnel(%WorkingCopy{main: true} = harness, attrs) do
    save(harness, Map.take(attrs, [:preview_url, :preview_tunnel_id, :preview_tunnel_secret]))
  end

  def record_preview_tunnel(%WorkingCopy{}, _attrs), do: {:error, :not_the_main_copy}

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

  # The device is written at mint rather than attached afterwards.
  #
  # `Devices.attach/2` runs on the channel join, so a copy minted any other way
  # — `mix cms.harness.onboard` posts to `/api/harnesses` — stayed device-less
  # until a harness happened to join for that root, and never if none did.
  # Measured on dev: 11 of 17 copies with no machine, and the newest of them
  # minted by an onboarding twenty minutes earlier.
  #
  # It also breaks recognition, which is the more expensive half.
  # `recognised/3` matches on `{project, device, root}`, so a mint that records
  # no device cannot be recognised by the next one either — the same checkout
  # onboarded twice is two rows, which is the duplicate this whole lookup exists
  # to prevent.
  # Refused rather than minted machine-less. A row that is ever seen must name a
  # device — `seen_copies_are_on_a_machine`, `device_id IS NOT NULL OR
  # last_seen_at IS NULL` — so minting one without would defer the failure to
  # the first connection, where a constraint violation reads as a crash rather
  # than as an answer.
  #
  # Both callers can say which machine they are. A harness join carries it in
  # the payload; onboarding reads the identity this machine already holds and
  # announces one if it has none. A caller that says nothing is a client too old
  # to know about devices, and the useful thing to tell it is to update — not to
  # write a row that nothing can attribute and that `location/1` cannot answer
  # for.
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

        # The caller's id when it has one, and only then.
        #
        # `mint/2` writes an id into the checkout's `.cms_harness.json` before
        # the server is told anything, precisely so the file and the row hold
        # one value rather than two derivations of it. This generated its own
        # regardless, so a copy made by the tool had one id on disk and a
        # different one in the database — and would present the file's on join,
        # be recognised by nothing, and mint a third row.
        #
        # Found by running it once against a real harness. The in-process double
        # asserts the tool's reply and never compares it to what was written,
        # so every test passed over it.
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

  # The label refreshes on every join *while it is still the auto-generated
  # one* — a checkout moves, a container is recreated with a new hostname,
  # and following that costs nothing since nobody has named this copy yet.
  #
  # It used to refresh unconditionally, on the theory that the label is
  # display only so keeping it current costs nothing. That reasoning skipped
  # the one thing a join cannot tell apart from its own default: a name a
  # person chose with `relabel/3`. `CmsHarness.Config.label/1` sends its
  # computed default on *every* connect, and a harness reconnects on every
  # restart and every server-side refresh — so a rename that survived until
  # the next reconnect was luck, not the promise `relabel/3`'s own doc makes.
  # John: "these the names of these working copies keeps reverting to the
  # automatically generated crap."
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
    # The agents first, and outside the transaction, because stopping one is a
    # request to a machine rather than a write.
    #
    # A copy is the boundary of the work — story 964's rule, John: "I can keep
    # them through that whole epic and then I can discard the working copy". So
    # discarding has to end them, and an agent that outlived its checkout would
    # be a model held open against a directory that is not there, still holding
    # a subscription slot and still spending. Story 961 is the same concern
    # arriving from the other side.
    #
    # Best-effort, and it does not block the offboard. The copy this is most
    # often used on is one whose machine has gone — that is story 892's whole
    # premise — and refusing to let go of a checkout because nothing can be
    # reached to stop an agent on it would make the vanished case unofboardable,
    # which is the one case the control exists for.
    agents = stop_agents_on(scope, id)

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

      Map.merge(%{files: files, problems: problems, components: components}, agents)
    end)
    |> case do
      {:ok, counts} ->
        tell_the_machine(id)
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

  # Offboarding is the one operation that should release the machine's channel
  # and watchers, and it was the one that did not.
  #
  # A copy removed here stayed served there forever: still joined, still holding
  # a project supervisor, still scanning a directory that no longer exists — and
  # logging "This is a harness fault — a wrong working directory or an unreadable
  # checkout" on every cycle, which is a correct guard and exactly the wrong
  # description of a copy somebody retired on purpose. Nothing but a restart
  # cleared it, which is why it went unnoticed. Issue 03ea1ee5.
  #
  # Best-effort, after the transaction, and never able to fail the offboard. The
  # machine may be off, and a copy whose machine is gone is precisely the one an
  # operator most needs to remove. A push that does not land costs a stale
  # subtree until that harness next restarts — the state before this existed, so
  # the floor is unchanged.
  #
  # Fire-and-forget rather than the `ref`-and-await shape `stop_agent` uses, for
  # the same reason: there is nothing to learn from the answer that would change
  # what we do, and waiting would hand an offboard a way to hang.
  defp tell_the_machine(working_copy_id) do
    case Analysis.executor_holder(working_copy_id) do
      {:ok, pid, _instance} -> send(pid, {:offboarded, working_copy_id})
      _ -> :ok
    end
  end

  @doc """
  Make a working copy for this project and staff it.

  One act with two halves in two places: the harness makes the checkout on its
  own disk and writes the identity into it, and this records the copy and starts
  the agents that will work in it. The caller makes one call.

  Here rather than in the MCP tool because it has two callers with nothing else
  in common — an agent asking for somewhere to work, and `EpicDispatch` placing
  an epic that has nowhere to go. A tool cannot be the home of that: `McpServers`
  depends on this context and not the other way round, so `EpicDispatch` calling
  the tool would be the dependency backwards.

  Answers `{:ok, copy, staffed}` where `staffed` is `ensure_copy_agents/2`'s
  report, so the caller can say which agents came up and which did not. A copy
  that could not be staffed is still a copy: the checkout exists and the failure
  belongs in front of somebody, not in a rollback.
  """
  @spec mint(Scope.t(), keyword()) ::
          {:ok, WorkingCopy.t(), map()} | {:error, term()}
  def mint(%Scope{active_project_id: project_id} = scope, opts \\ [])
      when is_binary(project_id) do
    # Only copies that are checkouts. A row is not one until it reports a root —
    # `ensure_default/1` mints a rootless nil-object row — and a machine is only
    # a candidate host if it actually holds the repository.
    # The main checkout first, then anything else that is a checkout.
    #
    # Order matters and it is not a preference. A new copy is made *beside* the
    # host — `.claude/worktrees/<name>` under its root — so a host that is
    # itself a worktree nests one inside another. Run live once, the first copy
    # this made landed at
    # `…/worktrees/agent-conversation-ui/.claude/worktrees/live-smoke-test-one`,
    # because `host_holder/1` takes whichever candidate is connected and the
    # list happened to start with a worktree.
    #
    # The main checkout is the one place a sibling is a sibling. Everything else
    # stays in the list because a project whose main copy is not connected
    # should still be able to make one, and a nested worktree is worse than no
    # worktree only in tidiness — it still works.
    copies =
      scope
      |> list_harnesses()
      |> Enum.filter(&(is_binary(&1.root) and &1.root != ""))

    candidates =
      copies
      |> Enum.sort_by(& &1.main, :desc)
      |> Enum.map(& &1.id)

    request = %{
      "project_id" => project_id,
      # The identity travels *to* the harness rather than back from it, so the
      # file on disk and the row here hold one value rather than two derivations
      # of it — the failure story 891 exists to end.
      "working_copy_id" => Ecto.UUID.generate(),
      "label" => opts[:label],
      "root" => opts[:root],
      # A copy that cannot authenticate is a copy that never joins, so the key
      # goes with it. `ensure_deploy_key/2` mints one if the project has none —
      # a new project does not get one at creation, and everything that must
      # authenticate as the project has to ask for it first.
      "deploy_key" => opts[:deploy_key] || deploy_key(scope)
    }

    with {:ok, %{root: root, working_copy_id: id}} <-
           Transport.impl().create_working_copy(candidates, request, 60_000),
         {:ok, copy} <-
           issue(scope, id,
             root: root,
             label: opts[:label],
             device: host_device(scope),
             # Not a suggestion. This id is already written into the checkout's
             # own config, and a row under a different one is a copy nothing can
             # recognise.
             working_copy_id: id
           ),
         {:ok, copy} <- report_root(copy, root) do
      {:ok, copy, Agents.ensure_copy_agents(scope, copy)}
    end
  end

  # `ensure_deploy_key/2` takes the project and answers the project, minting a
  # key onto it if it has none — a new project does not get one at creation, and
  # everything that must authenticate as the project has to ask first.
  #
  # `nil` when there is no project in scope to ask about, which the harness
  # handles: the copy is written without a key and joins on whatever the machine
  # already holds. Not rescued — an unexpected shape here should be loud, and
  # the version this replaced swallowed a FunctionClauseError for a whole
  # session.
  defp deploy_key(%Scope{active_project: %Project{} = project} = scope) do
    case Projects.ensure_deploy_key(scope, project) do
      {:ok, %Project{deploy_key: key}} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp deploy_key(%Scope{}), do: nil

  # The machine the host copy is on. A created copy sits on the same filesystem
  # as the checkout it was made beside, so it is on the same device — and
  # recording that is what stops two machines' copies at one path being confused.
  defp host_device(scope) do
    scope
    |> list_harnesses()
    |> Enum.find_value(& &1.device_id)
  end

  # Stop everything on this copy, and say what would not stop.
  #
  # Counted rather than swallowed: "3 agents stopped" and "3 agents stopped, 1
  # still running" are different facts and the person offboarding needs the
  # second one, because the remedy is theirs — a process on a machine we could
  # not reach is not something the server can end on its own.
  defp stop_agents_on(scope, working_copy_id) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(&(&1.working_copy_id == working_copy_id and &1.status != :stopped))
    |> Enum.reduce(%{agents_stopped: 0, agents_left_running: []}, fn agent, acc ->
      case Agents.stop_agent(scope, agent.id) do
        {:ok, _stopped} ->
          %{acc | agents_stopped: acc.agents_stopped + 1}

        {:error, reason} ->
          Logger.warning(
            "[WorkingCopies] offboarding #{working_copy_id}: could not stop agent " <>
              "#{agent.id} (#{inspect(reason)}); it may still be running"
          )

          %{acc | agents_left_running: [agent.id | acc.agents_left_running]}
      end
    end)
  end

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
