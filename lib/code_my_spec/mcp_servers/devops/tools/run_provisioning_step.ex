defmodule CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep do
  @moduledoc """
  Run one named provisioning step directly, skipping the sequence's own
  halt-on-first-failure ordering.

  `run_devops_setup` walks `Sequence.for_options/1` in order and halts at the
  first step that is not done — the ordering *is* the dependency model, so a
  step later in the sequence normally has no business running before an
  earlier one does. That stops being true the moment an earlier step is
  blocked for a reason that has nothing to do with whether later steps can
  actually succeed: `:repository` and `:secrets` need to run real commands
  against a local checkout, which nothing reached through the light harness
  (`/mcp/harness`) can currently do — so they read "missing" indefinitely
  regardless of whether the account's real infrastructure (`:server`,
  `:domain`, `:dns`, and anything else that is purely a provider API call) is
  actually fine. Waiting on the sequence to reach them means never verifying
  the parts that already work.

  This is the same `run_step/3` `run_devops_setup` and `adopt_repository`
  both already use underneath — verified against the provider first, same
  `RunLock` respected, same honest outcome reported back. It does not bypass
  a step's own verification; it only bypasses *ordering*. Running `:deploy`
  before `:server` genuinely exists is still that step's problem to refuse,
  not this tool's to prevent.

  ## `inbound_probe_to` is the other gap `adopt_repository` already had

  `Steps.run(:inbound, ...)` already accepts `opts[:inbound_probe_to]` — an
  address on the project's own domain to prove receiving actually works,
  since Resend accepts mail only to addresses configured for the domain and
  offers no way to ask which those are. This tool never exposed a way to
  supply one, so the step paused indefinitely asking for something a caller
  had no parameter to give it — the same shape as `adopt_repository`'s
  missing `:owner` before it could name an organisation's repository.

  ## `confirm_apex_repoint` is the same gap, for `:dns`

  `Steps.apex_repoint/4` refuses to move a live apex onto a freshly created
  server without `opts[:confirm_apex_repoint]` — reasonable, since the apex
  might be serving real traffic today. But that flag was only ever threaded
  from `CodeMySpecWeb.ProvisioningLive`'s own `"confirm_apex_repoint"` event,
  so an agent driving this tool instead of a human clicking a button had no
  way to say yes: every retry re-detected the live apex and paused again,
  identically, with `devops_status` never explaining why nothing progressed.
  Confirmed live: a prod cutover the operator had already approved sat paused
  through repeated retries because the only "confirm" that existed was a
  LiveView click nothing here could reach.

  ## The `:server` step never creates a server here, under any circumstance

  `Steps.server_creation_gate/3` used to accept `opts[:confirm_new_server]`
  as a way to create a brand-new server for an unlinked environment anyway —
  removed after `broken-oaths-uat` and `broken-oaths-prod` got created by
  accident this way instead of sharing the account's existing
  `fuellytics`/`fuellytics-prod` boxes. There is no escape hatch left: an
  unlinked environment's `:server` step always pauses, naming what the
  account would need to link first. Only `Steps.provision_account_server/3`,
  reached through the account-level provisioning tool, may create one.

  ## This returns as soon as the step starts, not when it finishes

  Same reason `run_devops_setup` already documents this, for the same
  underlying cost: `:deploy` alone has measured ~167s, far longer than the
  code-mode sandbox's own 30s wall clock. This used to call `Provisioning.
  run_step/2` and wait, which is exactly the shape `run_step_async/3`'s own
  moduledoc describes as unsurvivable — confirmed live running `:deploy`
  against a harness-only project: every call was brutally killed at 30s with
  no trace of what it had started, indistinguishable from a hang. `RunLock`
  is what makes "started or refused" the only two outcomes here, the same
  handshake `Resources.fix_async/2` uses: the spawned task claims the lock
  and only then acks this call, so "started" means the run genuinely holds
  it. Call `devops_status` afterward to watch it converge.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Step
  alias CodeMySpec.Resources

  schema do
    field :step, :string,
      required: true,
      doc: "One of: #{Step.keys() |> Enum.map_join(", ", &to_string/1)}."

    field :inbound_probe_to, :string,
      doc:
        "For the \"inbound\" step only: an address on the project's own domain to " <>
          "prove receiving works (e.g. \"sam@example.com\"). Resend accepts mail only " <>
          "to addresses configured for the domain, so this cannot be guessed."

    field :confirm_apex_repoint, :boolean,
      doc:
        "For the \"dns\" step only: the apex already resolves somewhere, and this run " <>
          "would repoint it at a server it just created — which takes down whatever is " <>
          "live there today. The step pauses and names the current and new address " <>
          "instead of doing this silently; set this to true once that repoint is " <>
          "actually wanted, and call the step again."

    field :force, :boolean,
      doc:
        "Skip verification and run the step unconditionally, even if the provider " <>
          "already reports it satisfied. A step's own claim of \"satisfied\" can be " <>
          "narrower than everything its run actually does — e.g. \"server\" only checks " <>
          "the box and DATABASE_URL exist, not that the box's docker daemon trusts the " <>
          "registry it should. Every step's run is idempotent, so this is safe to use " <>
          "whenever a step reports done but something it should have set up still isn't."
  end

  @impl true
  def execute(%{step: step} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope),
         {:ok, key} <- find_step(step) do
      scope
      |> Resources.project_scope(project)
      |> start_step_async(project, key, run_opts(params))
      |> reply(step, project, frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp run_opts(params) do
    inbound_opts =
      case Map.get(params, :inbound_probe_to) do
        to when is_binary(to) and to != "" -> [inbound_probe_to: to]
        _ -> []
      end

    dns_opts =
      case Map.get(params, :confirm_apex_repoint) do
        true -> [confirm_apex_repoint: true]
        _ -> []
      end

    force_opts =
      case Map.get(params, :force) do
        true -> [force: true]
        _ -> []
      end

    inbound_opts ++ dns_opts ++ force_opts
  end

  defp find_step(step) do
    case Enum.find(Step.keys(), &(to_string(&1) == step)) do
      nil -> {:error, "unknown step #{inspect(step)} — must be one of #{Enum.map_join(Step.keys(), ", ", &to_string/1)}"}
      key -> {:ok, key}
    end
  end

  # Same `:provisioning_run_async` flag `Provisioning.run_step_async/3`
  # reads, for the same reason: a spawned `Task.Supervisor` child is a
  # genuinely different process, so under test it holds neither the caller's
  # Ecto Sandbox checkout nor its `Req.Test` stub allowances. Synchronous
  # under test shares those instead of racing the test's own lifetime.
  defp start_step_async(scope, project, key, opts) do
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true -> spawn_step_async(scope, project, key, opts)
      _ -> RunLock.with_lock(project.id, fn -> Provisioning.run_step(scope, key, opts) end)
    end
  end

  # `Resources.start_fix_async/3`'s handshake, for one named step instead of
  # the whole sequence: the spawned task claims `RunLock` first and only then
  # signals this call, so the caller learns the true outcome — locked and
  # running, or refused — in milliseconds, without ever waiting on the step
  # itself. The step keeps running under `CodeMySpec.TaskSupervisor`, a
  # process this call's own transport timeout (or the sandbox's 30s wall
  # clock) cannot reach.
  defp spawn_step_async(scope, project, key, opts) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        RunLock.with_lock(project.id, fn ->
          send(parent, {ref, :locked})
          Provisioning.run_step(scope, key, opts)
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

  defp reply({:ok, :started}, step, project, frame) do
    {:reply,
     ok("#{step} for #{project.name} started — call devops_status to watch it converge"), frame}
  end

  # The synchronous (test-mode) outcomes — `Provisioning.run_step/2`'s own
  # result, unchanged from before this tool went async.
  defp reply({:ok, %{state: state}}, step, project, frame) do
    {:reply, ok("#{step} for #{project.name} is now #{state}."), frame}
  end

  # Paused is a real, expected outcome — waiting on something only a person
  # can do — not a failure of this call.
  defp reply({:halt, %{state: :paused}, reason}, step, project, frame) do
    {:reply, ok("#{step} for #{project.name} is paused: #{reason}"), frame}
  end

  defp reply({:halt, %{state: state}, reason}, step, project, frame) do
    {:reply, error("#{step} for #{project.name} is now #{state}: #{reason}"), frame}
  end

  defp reply({:error, {:already_running, started_at}}, _step, _project, frame) do
    since = started_at && " (started #{started_at})"
    {:reply, error("a setup run is already in progress for this project#{since} — call devops_status rather than retrying"), frame}
  end

  defp reply({:error, :lock_handshake_timeout}, step, project, frame) do
    {:reply,
     error(
       "could not confirm #{step} started for #{project.name} — check devops_status, or try again shortly"
     ), frame}
  end

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not run the step: #{inspect(reason)}")
end
