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
  end

  @impl true
  def execute(%{step: step} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope),
         {:ok, key} <- find_step(step) do
      scope
      |> Resources.project_scope(project)
      |> start_step_async(project, key)
      |> reply(step, project, frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
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
  defp start_step_async(scope, project, key) do
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true -> spawn_step_async(scope, project, key)
      _ -> RunLock.with_lock(project.id, fn -> Provisioning.run_step(scope, key) end)
    end
  end

  # `Resources.start_fix_async/3`'s handshake, for one named step instead of
  # the whole sequence: the spawned task claims `RunLock` first and only then
  # signals this call, so the caller learns the true outcome — locked and
  # running, or refused — in milliseconds, without ever waiting on the step
  # itself. The step keeps running under `CodeMySpec.TaskSupervisor`, a
  # process this call's own transport timeout (or the sandbox's 30s wall
  # clock) cannot reach.
  defp spawn_step_async(scope, project, key) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        RunLock.with_lock(project.id, fn ->
          send(parent, {ref, :locked})
          Provisioning.run_step(scope, key)
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
