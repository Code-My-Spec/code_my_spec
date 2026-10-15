defmodule CodeMySpec.Resources do
  @moduledoc """
  What the account should have, against what it actually has.

  ## Two checks, one answer

  **Per project** the expected set comes from `ProvisioningPlan.Sequence` and the
  project's chosen options — the same source the run itself uses.

  **Across the account** the checks no single project can make: a DNS record
  aimed at an address no server holds, a bucket no environment names.

  Projects count when `devops != :off`, whether or not setup has run. The
  actual side always comes from the providers, never from stored step state.
  See knowledge/infrastructure, "Resource health".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.LocalScope,
      CodeMySpec.Projects,
      CodeMySpec.Provisioning,
      CodeMySpec.Provisioning.Hetzner,
      CodeMySpec.ProvisioningPlan,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ]

  import Ecto.Query

  alias CodeMySpec.LocalScope
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpec.ProvisioningPlan
  alias CodeMySpec.ProvisioningPlan.Step
  alias CodeMySpec.Repo
  alias CodeMySpec.Resources.Acknowledgement
  alias CodeMySpec.Resources.Inventory
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

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

    # `:unknown` is the absence of an answer, not a problem.
    problems =
      Enum.count(resources, &(&1.status == :dangling)) +
        Enum.count(checklist, &(&1.state == :missing))

    %{
      # An unreadable provider is not a clean bill.
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

  Separate from `trim/1` on purpose: a kept resource never appears in the set
  the delete path is handed, rather than relying on that path to check a flag.
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
      nil -> Teardown.resource(scope, Map.put(resource, :origin, "created"))
      fun -> fun.(scope, resource)
    end
  end

  @doc """
  Run one project's setup, converging on whatever is missing.

  Runs the whole sequence rather than one step: steps depend on each other,
  and the sequence is idempotent, building what is absent and leaving the rest.
  """
  @spec fix(Scope.t(), Ecto.UUID.t()) :: term()
  def fix(%Scope{} = scope, project_id) when is_binary(project_id) do
    case Enum.find(Projects.list_projects(scope), &(&1.id == project_id)) do
      nil ->
        {:error, :not_found}

      project ->
        project_scope = project_scope(scope, project)

        # The configured step opts, which the run does not read itself;
        # omitting them silently runs the real providers.
        Provisioning.run(project_scope, Provisioning.setup_options(project), step_opts())
    end
  end

  @doc """
  Run setup for every project meant to be deployed.

  Each runs on its own: a refusal halts that project and nothing else.
  """
  @spec fix_all(Scope.t()) :: [{Ecto.UUID.t(), term()}]
  def fix_all(%Scope{} = scope) do
    for project <- deployable(scope), do: {project.id, fix(scope, project.id)}
  end

  @doc """
  Start one project's setup without waiting for it to finish.

  For callers that cannot hold a connection for a whole run (an MCP call
  times out long before a deploy finishes). Returns as soon as the run has
  started or been refused; a project already mid-run gets
  `{:error, {:already_running, started_at}}` from `RunLock` without a second
  run starting. The caller polls `report/1` to watch it converge.

  `opts[:holder]` is what `RunLock.with_lock/3` records as the run's holder;
  `opts[:on_finish]` is called with the run's result when it lands — how the
  agent that started it is told, without this module knowing agents exist.
  """
  @spec fix_async(Scope.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, :started}
          | {:error, :not_found}
          | {:error, {:already_running, DateTime.t() | nil}}
          | {:error, :lock_handshake_timeout}
  def fix_async(%Scope{} = scope, project_id, opts \\ []) when is_binary(project_id) do
    case Enum.find(Projects.list_projects(scope), &(&1.id == project_id)) do
      nil -> {:error, :not_found}
      project -> start_fix(scope, project, opts)
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
    for project <- deployable(scope), do: {project.id, start_fix(scope, project, [])}
  end

  # The spawned task claims the lock first, then signals the caller, so "did it
  # start" is answered synchronously without waiting on the run. Inline in
  # tests (`:provisioning_async`), where a separate process would hold neither
  # the sandbox checkout nor the Req.Test stubs.
  defp start_fix(scope, project, opts) do
    project_scope = project_scope(scope, project)
    options = Provisioning.setup_options(project)

    if Application.get_env(:code_my_spec, :provisioning_async, true),
      do: start_fix_async(project_scope, project, options, opts),
      else: start_fix_inline(project_scope, project, options, opts)
  end

  defp start_fix_inline(project_scope, project, options, opts) do
    case run_fix(project_scope, project, options, opts, fn -> :ok end) do
      {:error, {:already_running, _}} = refused -> refused
      _finished -> {:ok, :started}
    end
  end

  defp start_fix_async(project_scope, project, options, opts) do
    parent = self()
    ref = make_ref()
    locked = fn -> send(parent, {ref, :locked}) end

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        case run_fix(project_scope, project, options, opts, locked) do
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

  # `on_finish` runs after the lock is released, so a starter it wakes is no
  # longer held by the run.
  defp run_fix(project_scope, project, options, opts, locked) do
    result =
      RunLock.with_lock(
        project.id,
        fn ->
          locked.()
          Provisioning.run(project_scope, options, step_opts())
        end,
        Keyword.get(opts, :holder, [])
      )

    finished(result, Keyword.get(opts, :on_finish))
    result
  end

  defp finished({:error, {:already_running, _}}, _on_finish), do: :ok
  defp finished(_result, nil), do: :ok
  defp finished(result, on_finish), do: on_finish.(result)

  defp step_opts, do: Application.get_env(:code_my_spec, :provisioning_step_opts, [])

  defp config(key), do: Application.get_env(:code_my_spec, __MODULE__, [])[key]

  @doc """
  One project's own status — what it should have against what it actually
  has, for that project alone.

  Unlike `report/1` (the whole account), this never looks past the one
  project it is given: no `deployable/1`, no `Inventory.list/1`, nothing that
  could name another project. A harness-scoped caller must not learn another
  project's state.

  Errors when this project's own devops level is off — nothing to report,
  not another project's checklist instead.
  """
  @spec project_report(Scope.t(), Project.t()) ::
          {:ok, report()} | {:error, :devops_off}
  def project_report(%Scope{} = scope, %Project{} = project) do
    case ProvisioningPlan.devops(scope, project) do
      :off ->
        {:error, :devops_off}

      _ ->
        checklist = ProvisioningPlan.checklist(scope, project)
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

  @doc """
  The setup steps `environment` still misses. See
  `ProvisioningPlan.setup_missing/3`, which the deploy requirement reads directly.
  """
  defdelegate setup_missing(scope, project, environment), to: ProvisioningPlan

  # What each project meant to be deployed should have, from the same sequence
  # the run uses; steps nobody started appear because the plan fills them in.
  defp checklist(scope) do
    for project <- deployable(scope),
        entry <- ProvisioningPlan.checklist(scope, project),
        do: entry
  end

  defp deployable(scope) do
    Enum.filter(Projects.list_projects(scope), &(ProvisioningPlan.devops(scope, &1) != :off))
  end

  @doc """
  A caller scope acting as `project`, retaining only a working copy that
  belongs to that project.

  Execution environments are resolved by the action that needs them. This
  function preserves caller identity and makes cross-project selection safe.
  """
  @spec project_scope(Scope.t(), Project.t()) :: Scope.t()
  def project_scope(%Scope{} = scope, %Project{id: project_id} = project) do
    case matching_working_copy(scope.active_working_copy_id, project_id) do
      {:ok, %{id: copy_id, root: root}} ->
        %{
          scope
          | active_project: project,
            active_project_id: project_id,
            active_working_copy_id: copy_id,
            cwd: root
        }

      :error ->
        %{
          scope
          | active_project: project,
            active_project_id: project_id,
            active_working_copy_id: nil,
            cwd: local_cwd(project)
        }
    end
  end

  defp matching_working_copy(copy_id, project_id) when is_binary(copy_id) do
    case WorkingCopies.fetch(copy_id) do
      {:ok, %{id: ^copy_id, project_id: ^project_id} = copy} ->
        {:ok, copy}

      _ ->
        :error
    end
  end

  defp matching_working_copy(_copy_id, _project_id), do: :error

  defp local_cwd(project) do
    case LocalScope.environment(project) do
      %{cwd: cwd} -> cwd
      _ -> nil
    end
  end

  # Everything the cross-checks need, gathered once.
  defp world(scope, found, errors) do
    recorded = recorded_resources(scope)

    %{
      live_addresses:
        MapSet.new(for %{kind: "server", identifier: ip} <- found, is_binary(ip), do: ip),
      recorded_addresses: addresses_in(recorded),
      recorded_buckets: names_in(recorded, "bucket"),
      # Hetzner unreadable means the comparison set is missing, not empty.
      servers_known?: not Map.has_key?(errors, :hetzner),
      bucket_names: bucket_names(scope),
      kept: Acknowledgement.kept(scope)
    }
  end

  # Dangling is defined per kind, and a resource can only dangle if it was
  # **ours**: "points at something we released", not "points somewhere we do
  # not recognise". See knowledge/infrastructure, "Resource health".
  defp classify(%{kind: "dns_record"} = resource, world) do
    put(resource, :domain, dns_status(address_of(resource), world), world.kept)
  end

  # Same rule: only a bucket we created that no environment names dangles.
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
      # Never one of ours.
      not MapSet.member?(world.recorded_addresses, address) -> :present
      # Ours, and we cannot see what is running to know if it still is.
      not world.servers_known? -> :unknown
      MapSet.member?(world.live_addresses, address) -> :present
      true -> :dangling
    end
  end

  # Only an A record can dangle against a server address.
  defp address_of(%{identifier: "A " <> address}), do: String.trim(address)
  defp address_of(_resource), do: nil

  # What setup recorded making, across the account: what makes "released"
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

  # A kept dangling resource is `:kept`: still listed, no longer counted.
  # Marking says "keep this", never "hide this".
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
    # Whether *we* made it is a separate question trimming needs answered.
    |> Map.put_new(:origin, :unrecorded)
  end
end
