defmodule CodeMySpec.Resources do
  @moduledoc """
  What the account should have, against what it actually has.

  ## Two checks, one answer

  **Per project** the expected set comes from `Provisioning.Sequence` and the
  project's chosen options — the same source the run itself uses, so the
  checklist cannot disagree with the thing that does the work. A second
  manifest would be a second truth, and this page exists because the first one
  was already hard enough to trust.

  **Across the account** the checks no single project can make: a DNS record
  aimed at an address no server holds, a bucket no environment names. Neither
  the record nor the server is wrong on its own. What is wrong is the
  relationship, and only something looking at everything can see a relationship.

  ## Which projects count

  `devops != :off`. That setting is the statement "this one is meant to be
  deployed", and it is the only thing that should decide. Inferring intent from
  whether setup happens to have run would let a project you turned on and never
  provisioned report as healthy — the case most worth flagging.

  ## Never from stored step state

  `provisioning_steps.state` records what happened on the last run. A
  certificate that expired since then still reads `done`. The expected side is
  ours; the actual side is the providers', every time.
  """

  import Ecto.Query

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Step
  alias CodeMySpec.Repo
  alias CodeMySpec.Resources.Acknowledgement
  alias CodeMySpec.Resources.Inventory
  alias CodeMySpec.Users.Scope

  @type report :: %{
          status: :healthy | :unhealthy,
          problems: non_neg_integer(),
          resources: [map()],
          checklist: [map()],
          errors: %{atom() => term()}
        }

  @doc """
  The account's health: what exists, what should and does not, and what points
  at nothing.
  """
  @spec report(Scope.t()) :: report()
  def report(%Scope{} = scope) do
    answers = Inventory.list(scope)
    errors = for {provider, {:error, reason}} <- answers, into: %{}, do: {provider, reason}
    found = for {_p, {:ok, list}} <- answers, resource <- list, do: resource

    checklist = checklist(scope)
    world = world(scope, found, errors)
    resources = Enum.map(found, &classify(&1, world))

    # `:unknown` is not a problem. It is the absence of an answer, and counting
    # it would turn one provider's outage into a page full of complaints about
    # resources nothing is wrong with.
    problems =
      Enum.count(resources, &(&1.status == :dangling)) +
        Enum.count(checklist, &(&1.state == :missing))

    %{
      # An unreadable provider is not a clean bill. We do not know what it
      # holds, and saying "healthy" would be a guess dressed as an all-clear.
      status: if(problems == 0 and errors == %{}, do: :healthy, else: :unhealthy),
      problems: problems,
      resources: Enum.sort_by(resources, &{&1.owner, &1.kind, &1.location}),
      checklist: checklist,
      errors: errors
    }
  end

  ## Acting on what the report found

  @doc """
  Mark a resource as deliberate, so it stops counting against the account.
  """
  @spec keep(Scope.t(), String.t(), String.t()) :: {:ok, Acknowledgement.t()} | {:error, term()}
  defdelegate keep(scope, kind, location), to: Acknowledgement

  @doc "Undo `keep/3`, putting the resource back among the dangling."
  @spec release(Scope.t(), String.t(), String.t()) :: :ok
  defdelegate release(scope, kind, location), to: Acknowledgement

  @doc """
  Everything trim would remove: dangling, and only dangling.

  Separate from `trim/1` on purpose. A resource Sam has said to keep must not
  appear in the set the delete path is handed at all — a guarantee that
  depends on the delete path checking a flag has already put an irreversible
  button underneath something he asked to keep.
  """
  @spec trim_candidates(Scope.t()) :: [map()]
  def trim_candidates(%Scope{} = scope) do
    scope |> report() |> Map.fetch!(:resources) |> Enum.filter(&(&1.status == :dangling))
  end

  @doc """
  Delete every dangling resource at its provider.

  Runs through `Teardown.resource/3`, which knows how to remove each kind and
  already refuses anything setup merely adopted. What reaches it is
  `trim_candidates/1`, so a kept resource is never a candidate rather than
  being filtered out late.
  """
  @spec trim(Scope.t()) :: %{ok: [map()], error: [{map(), term()}]}
  def trim(%Scope{} = scope) do
    scope
    |> trim_candidates()
    |> Enum.reduce(%{ok: [], error: []}, fn resource, acc ->
      case remove(scope, resource) do
        {:ok, _} -> %{acc | ok: [resource | acc.ok]}
        {:error, reason} -> %{acc | error: [{resource, reason} | acc.error]}
      end
    end)
  end

  defp remove(scope, resource) do
    case config(:trim) do
      nil -> CodeMySpec.Provisioning.Teardown.resource(scope, Map.put(resource, :origin, "created"))
      fun -> fun.(scope, resource)
    end
  end

  @doc """
  Run one project's setup, converging on whatever is missing.

  The action is the project's sequence rather than an individual step. Steps
  are ordered and depend on each other, so running one alone fails whenever
  the gap is not the very next one — and fails in a way that reads like a
  broken feature rather than an ordering constraint. The sequence is already
  idempotent, which is what makes it safe to offer: it builds what is absent
  and leaves what is not.
  """
  @spec fix(Scope.t(), Ecto.UUID.t()) :: term()
  def fix(%Scope{} = scope, project_id) when is_binary(project_id) do
    case Enum.find(Projects.list_projects(scope), &(&1.id == project_id)) do
      nil ->
        {:error, :not_found}

      project ->
        project_scope = project_scope(scope, project)

        # The same opts `ProvisioningLive` passes. `run_step/3` does not read
        # this env itself, so a caller that omits it silently runs the real
        # providers — which is what this did first time round, failing every
        # step against credentials that were never meant to be used.
        Provisioning.run(project_scope, Provisioning.setup_options(project), step_opts())
    end
  end

  @doc """
  Run setup for every project meant to be deployed.

  Each runs on its own: a refusal halts that project and nothing else. One
  provider saying no to one project must not decide what happens to the rest,
  or the button is unusable on any account with more than one.
  """
  @spec fix_all(Scope.t()) :: [{Ecto.UUID.t(), term()}]
  def fix_all(%Scope{} = scope) do
    for project <- deployable(scope), do: {project.id, fix(scope, project.id)}
  end

  @doc """
  Start one project's setup without waiting for it to finish.

  `fix/2` blocks for the whole run, which is the honest shape for a page
  holding a connection open — and exactly what breaks a caller that cannot:
  the MCP transport's call timeout is far shorter than a real run (deploy
  alone measured ~167s), so `run_devops_setup` calling `fix/2` returned
  `-32603` to the caller long before the run itself finished. The run kept
  going server-side regardless, and the caller — reading the timeout as
  failure — retried into a project that already had a run in flight, racing
  its own writes against real Cloudflare/Hetzner/Resend/GitHub state.

  This returns as soon as the run has either started or been refused —
  never once the work is done. `RunLock` is what makes "started or refused"
  the only two outcomes: a project already mid-run gets
  `{:error, {:already_running, started_at}}` back immediately, without a
  second `Provisioning.run/3` ever starting. The caller polls
  `Resources.report/1` (what `devops_status` already reads) to watch it
  converge.
  """
  @spec fix_async(Scope.t(), Ecto.UUID.t()) ::
          {:ok, :started}
          | {:error, :not_found}
          | {:error, {:already_running, DateTime.t() | nil}}
          | {:error, :lock_handshake_timeout}
  def fix_async(%Scope{} = scope, project_id) when is_binary(project_id) do
    case Enum.find(Projects.list_projects(scope), &(&1.id == project_id)) do
      nil -> {:error, :not_found}
      project -> start_fix(scope, project)
    end
  end

  @doc """
  Start setup for every project meant to be deployed, without waiting for any
  of them.

  Each project gets its own `RunLock`, so one project's run already in
  flight refuses only that project — the rest still start, the same
  independence `fix_all/1` gives the synchronous path.
  """
  @spec fix_all_async(Scope.t()) :: [{Ecto.UUID.t(), term()}]
  def fix_all_async(%Scope{} = scope) do
    for project <- deployable(scope), do: {project.id, start_fix(scope, project)}
  end

  # The handshake that makes `fix_async/2` genuinely async while still
  # answering "did it start" synchronously: the spawned task claims the lock
  # first and only then signals the caller, so the caller learns the true
  # outcome — locked-and-running, or refused — in milliseconds, without ever
  # waiting on the run itself. `RunLock.with_lock/2`'s `Registry.register/3`
  # is the atomic step; the ack just carries its result back across process
  # boundaries so this function can return synchronously with an answer.
  #
  # In tests, run inline instead — same reasoning as `content_pull_async:
  # false`. The spawned Task is a genuinely different process, so it holds
  # neither the Ecto Sandbox checkout nor the Req.Test stub allowances the
  # test process set up; against fakes there is nothing to wait for anyway,
  # so running synchronously costs nothing and shares both.
  defp start_fix(scope, project) do
    project_scope = project_scope(scope, project)
    options = Provisioning.setup_options(project)

    if Application.get_env(:code_my_spec, :provisioning_async, true) do
      start_fix_async(project_scope, project, options)
    else
      RunLock.with_lock(project.id, fn -> Provisioning.run(project_scope, options, step_opts()) end)
      |> case do
        {:error, {:already_running, _}} = refused -> refused
        _finished -> {:ok, :started}
      end
    end
  end

  defp start_fix_async(project_scope, project, options) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        RunLock.with_lock(project.id, fn ->
          send(parent, {ref, :locked})
          Provisioning.run(project_scope, options, step_opts())
        end)
        |> case do
          {:error, {:already_running, _}} = refused -> send(parent, {ref, refused})
          _finished -> :ok
        end
      end)

    receive do
      {^ref, :locked} -> {:ok, :started}
      {^ref, {:error, {:already_running, _}} = refused} -> refused
    after
      5_000 -> {:error, :lock_handshake_timeout}
    end
  end

  defp step_opts, do: Application.get_env(:code_my_spec, :provisioning_step_opts, [])

  defp config(key), do: Application.get_env(:code_my_spec, __MODULE__, [])[key]

  @doc """
  One project's own status — what it should have against what it actually
  has, for that project alone.

  Unlike `report/1` (the whole account, for `/app/resources` — the
  cross-project dangling checks genuinely need to see everything, and
  `Inventory.list/1` asking each provider for every resource on the account
  is how they see it), this never looks past the one project it is given.
  A harness-scoped caller has no business learning what devops state,
  missing steps, or dangling resources some *other* project in the same
  account carries — least of all by accident, through a report that
  happened to include it regardless of whether the caller's own project
  was on or off.

  Confirmed live: `devops_status`'s original fix refused cleanly when the
  calling project's own devops was `:off`, but once it was turned on the
  tool still called `report/1` underneath — so a *different*,
  independently devops-enabled project in the same account kept appearing
  in full detail beside the real answer. This is what closes that: no
  `deployable/1`, no `Inventory.list/1`, nothing that could ever name a
  project other than the one given.

  Errors when this project's own devops level is off — nothing to report,
  not another project's checklist instead.
  """
  @spec project_report(Scope.t(), Project.t()) ::
          {:ok, report()} | {:error, :devops_off}
  def project_report(%Scope{} = scope, %Project{} = project) do
    case devops(scope, project) do
      :off ->
        {:error, :devops_off}

      _ ->
        checklist = project_checklist(scope, project)
        problems = Enum.count(checklist, &(&1.state == :missing))

        {:ok,
         %{
           status: if(problems == 0, do: :healthy, else: :unhealthy),
           problems: problems,
           resources: [],
           checklist: checklist,
           errors: %{}
         }}
    end
  end

  # What each project meant to be deployed should have, from the same sequence
  # the run uses. `plan/2` fills the gaps a run never reached, which is the
  # only reason a step nobody started can appear here at all.
  defp checklist(scope) do
    for project <- deployable(scope), entry <- project_checklist(scope, project), do: entry
  end

  defp project_checklist(scope, project) do
    for step <- Provisioning.plan(project_scope(scope, project), Provisioning.setup_options(project)) do
      %{
        project_id: project.id,
        project_name: project.name,
        key: step.key,
        state: if(step.state == :done, do: :present, else: :missing),
        detail: step.provider_error
      }
    end
  end

  defp deployable(scope) do
    Enum.filter(Projects.list_projects(scope), &(devops(scope, &1) != :off))
  end

  # Read, never `get_or_create/1`. Loading a page must not write: the first
  # version of this used the get-or-create and silently created a
  # configuration row for every project in the account the moment anyone
  # opened `/app/resources`.
  #
  # No row, or a row predating the column, means nobody has said this project
  # ships — which is `:off`, the same answer the schema default gives.
  defp devops(scope, project) do
    case Configurations.get(project_scope(scope, project)) do
      %{devops: devops} when not is_nil(devops) -> devops
      _ -> :off
    end
  rescue
    _ -> :off
  end

  # An MCP call arriving over a harness connection carries that harness's own
  # `environment` — `%Environment{type: :harness}`, correct for addressing
  # *this session's* working copy (analysis, hooks) but not a general command
  # runner: `CmsHarness.Environments.Harness.cmd/4` is a stub that always
  # returns `{:error, :not_supported_on_harness}`. Provisioning steps that
  # shell out (the repository push, most concretely) crashed on it —
  # `String.trim(:error)`, the stub's return value pattern-matched as if it
  # were `{output, status}` — rather than failing cleanly, because nothing
  # upstream expects `cmd/4` to disagree with its own declared contract.
  #
  # Provisioning has always run against the project's own checkout, regardless
  # of which session asked for it to run. Re-deriving `:local` here, the same
  # way `Scope.for_local_project/2` does, is what makes an MCP-invoked run
  # behave like the button on the page instead of like whichever connection
  # issued it.
  @doc """
  A scope acting as `project`, with an `environment` real commands can run in.

  Public because `project_scope/2` is the one place this coercion lives —
  anything that needs to run a provisioning-shaped action (a step, or a
  generator write) against a specific project from an MCP call should build
  its scope through this rather than re-deriving `:local` itself.
  """
  @spec project_scope(Scope.t(), Project.t()) :: Scope.t()
  # Always re-derived for the *target* project rather than trusting the
  # calling scope's own environment — a harness bound to project A iterating
  # over project B must not run B's steps against A's checkout, which is what
  # made this a separate branch from "keep what's already there" in the first
  # place. But re-deriving used to mean `project.local_path` alone, which
  # missed a project onboarded outside the usual local_path-setting flow
  # (adopted, no persisted column) even while a harness was live-registered
  # for it right now. `Scope.for_local_project/1` checks that registration
  # first and falls back to `local_path` only if nothing answers, so this
  # gets the same live-checkout preference the nil-environment clause below
  # already has.
  def project_scope(%Scope{environment: %Environment{type: :harness}} = scope, project) do
    environment =
      case Scope.for_local_project(project) do
        {:ok, %{environment: environment}} -> environment
        {:error, _reason} -> Environment.new(:local, project.local_path)
      end

    %Scope{scope | active_project: project, active_project_id: project.id, environment: environment}
  end

  # A scope built from an HTTP session — `/app/resources`' own button, unlike
  # `ProvisioningLive`'s — carries no environment at all: `Scope.for_user/1`
  # never sets one. Left alone, every shelling-out step (repository push,
  # deploy, backups) hit `is_nil(env(scope))` and errored with "no working
  # environment" on every run this page started — even for a project whose
  # checkout is real, current, and sitting right where `local_path` says.
  # The persisted `:repository` row (a step re-verified on every run,
  # deliberately — see `verify(:repository, …)`) then flipped from `:done` to
  # `:error`, and the checklist read that as a fresh "Missing" (issue a2ea10a8).
  #
  # `ProvisioningLive.with_project_environment/2` already solved this for the
  # per-project setup page by resolving through `Scope.for_local_project/2` —
  # which checks a live-registered harness before falling back to
  # `project.local_path`, so a currently-connected checkout wins over a stale
  # column. This mirrors it so the account-wide "Run setup" button gets the
  # same real environment instead of running blind.
  #
  # A project truly reachable nowhere (no registration, no `local_path`) still
  # falls through with `environment: nil`, and the shelling-out steps still
  # name that plainly rather than guessing — there is nothing to adopt here,
  # only somewhere real to look first.
  def project_scope(%Scope{environment: nil} = scope, project) do
    case Scope.for_local_project(project) do
      {:ok, %{environment: environment, cwd: cwd}} ->
        %Scope{
          scope
          | active_project: project,
            active_project_id: project.id,
            environment: environment,
            cwd: cwd
        }

      {:error, _reason} ->
        %Scope{scope | active_project: project, active_project_id: project.id}
    end
  end

  def project_scope(%Scope{} = scope, project) do
    %Scope{scope | active_project: project, active_project_id: project.id}
  end

  # Everything the cross-checks need, gathered once. Also the answer to an
  # N+1: `bucket_names/1` used to run per bucket.
  defp world(scope, found, errors) do
    recorded = recorded_resources(scope)

    %{
      live_addresses: MapSet.new(for %{kind: "server", identifier: ip} <- found, is_binary(ip), do: ip),
      recorded_addresses: addresses_in(recorded),
      recorded_buckets: names_in(recorded, "bucket"),
      # Whether we can say anything about what servers exist right now. When
      # Hetzner cannot be asked, the comparison set is missing rather than
      # empty, and treating those as the same thing flagged every A record on
      # the account during an outage.
      servers_known?: not Map.has_key?(errors, :hetzner),
      bucket_names: bucket_names(scope),
      kept: Acknowledgement.kept(scope)
    }
  end

  # Dangling is defined per kind, because "points at nothing" means something
  # different for each. One generic rule would either miss the DNS case or
  # flag things that are fine, and a flag that is wrong often enough stops
  # being read.
  #
  # The load-bearing qualifier throughout: a resource can only dangle if it
  # was **ours**. The first version flagged anything that did not match our
  # records, which on a real account means every record pointing at a host
  # somewhere else — six of seven flags on John's account were his own
  # marketing site on Fly. "Points at nothing" has to mean "points at
  # something we released", not "points somewhere we do not recognise".
  defp classify(%{kind: "dns_record"} = resource, world) do
    put(resource, :domain, dns_status(address_of(resource), world), world.kept)
  end

  # Same rule. A bucket we never created is somebody else's storage; a bucket
  # we did create and no environment names anymore is one we are paying for.
  defp classify(%{kind: "bucket"} = resource, world) do
    name = resource.location |> String.split("/") |> List.last()

    status =
      cond do
        MapSet.member?(world.bucket_names, name) -> :present
        MapSet.member?(world.recorded_buckets, name) -> :dangling
        true -> :present
      end

    put(resource, :account, status, world.kept)
  end

  defp classify(%{kind: kind} = resource, _world) when kind in ~w(ssh_key firewall) do
    put(resource, :account, :present)
  end

  defp classify(%{kind: "server"} = resource, _world), do: put(resource, :server, :present)
  defp classify(resource, _world), do: put(resource, :project, :present)

  defp dns_status(nil, _world), do: :present

  defp dns_status(address, world) do
    cond do
      # Never one of ours. Somebody else's host, and none of our business
      # whether it is still up.
      not MapSet.member?(world.recorded_addresses, address) -> :present
      # Ours, and we cannot see what is running to know if it still is.
      not world.servers_known? -> :unknown
      MapSet.member?(world.live_addresses, address) -> :present
      true -> :dangling
    end
  end

  # Only an A record can dangle against a server address. A CNAME or TXT points
  # at a name or a string, and checking those against IPs would flag every one
  # of them.
  defp address_of(%{identifier: "A " <> address}), do: String.trim(address)
  defp address_of(_resource), do: nil

  # What setup wrote down that it made, across every project on the account.
  # This is the record of what was once ours, which is what makes "released"
  # distinguishable from "never mine".
  defp recorded_resources(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    Step
    |> join(:inner, [s], p in Project, on: p.id == s.project_id)
    |> where([_s, p], p.account_id == ^account_id)
    |> select([s], s.resources)
    |> Repo.all()
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp recorded_resources(_scope), do: []

  defp addresses_in(recorded) do
    for %{kind: "server", identifier: identifier} <- recorded,
        is_binary(identifier),
        [address] <- [Regex.run(~r/\b\d{1,3}(?:\.\d{1,3}){3}\b/, identifier)],
        into: MapSet.new(),
        do: address
  end

  defp names_in(recorded, kind) do
    for %{kind: ^kind, location: location} <- recorded,
        is_binary(location),
        into: MapSet.new(),
        do: location |> String.split("/") |> List.last()
  end

  defp bucket_names(scope) do
    for project <- Projects.list_projects(scope),
        environment <- Provisioning.existing_environments(project_scope(scope, project)),
        into: MapSet.new() do
      "#{Provisioning.Repository.default_name(project)}-#{environment.name}"
    end
  end

  defp put(resource, owner, status), do: put(resource, owner, status, MapSet.new())

  # A dangling resource Sam has accounted for is `:kept` — still listed, still
  # saying what it is, and no longer counted against him. Marking says "keep
  # this", never "hide this": a resource nobody can see is the failure this
  # whole epic keeps finding.
  defp put(resource, owner, :dangling, kept) do
    if MapSet.member?(kept, {resource.kind, resource.location}) do
      build(resource, owner, :kept)
    else
      build(resource, owner, :dangling)
    end
  end

  defp put(resource, owner, status, _kept), do: build(resource, owner, status)

  defp build(resource, owner, status) do
    resource
    |> Map.put(:owner, owner)
    |> Map.put(:status, status)
    # Everything the providers report is something that exists; whether *we*
    # made it is a separate question, and one trimming needs answered before
    # it can offer to delete anything.
    |> Map.put_new(:origin, :unrecorded)
  end
end
