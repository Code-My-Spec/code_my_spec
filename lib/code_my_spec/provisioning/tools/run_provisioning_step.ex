defmodule CodeMySpec.Provisioning.Tools.RunProvisioningStep do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.Tools.Starter
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Truncate
  alias CodeMySpec.ProvisioningPlan.Step
  alias CodeMySpec.Resources

  @impl true
  def name, do: "run_provisioning_step"

  @impl true
  def description do
    """
    Run one named provisioning step directly, skipping the sequence's own
    halt-on-first-failure ordering.

    `run_devops_setup` walks `Sequence.for_options/1` in order and halts at the
    first step that is not done. That stops being useful when an earlier step is
    blocked for a reason unrelated to later ones — `:repository` and `:secrets`
    need a local checkout the light harness cannot provide, while provider-API
    steps (`:server`, `:domain`, `:dns`, …) can still be verified. This bypasses
    ordering only: the step is the same `Provisioning.run_step/3`, verified
    against the provider first, under the same `RunLock`, and a step that cannot
    run yet is still that step's to refuse.

    ## Confirmations an agent can give

    `inbound_probe_to`, `confirm_apex_repoint` and `confirm_inbound_mx_repoint`
    carry the answers a step pauses for, so an agent with no person at the
    console can supply them. `:server` never creates a server here: an unlinked
    environment's step always pauses; only `Steps.provision_account_server/3`,
    through the account-level tool, creates one.

    ## Returns when the step starts, not when it finishes

    A step can outlive the caller's transport and the code-mode sandbox's 30s
    wall clock (`:deploy` takes minutes). The spawned task claims `RunLock` and
    only then acks, so the reply is "started" or "already running". An agent
    that started the step is messaged its outcome; any other caller watches
    `devops_status`.

    See knowledge/tools, "run_provisioning_step".
    """
  end

  @impl true
  def params do
    %{
      force:
        {:meta, :boolean,
         [
           description:
             "Skip verification and run the step unconditionally, even if the provider already reports it satisfied. A step's own claim of \"satisfied\" can be narrower than everything its run actually does — e.g. \"server\" only checks the box and DATABASE_URL exist, not that the box's docker daemon trusts the registry it should. Every step's run is idempotent, so this is safe to use whenever a step reports done but something it should have set up still isn't."
         ]},
      step:
        {:required,
         {:meta, :string,
          [
            description:
              "One of: repository, server, secrets, domain, dns, tls, deploy, email, inbound, storage, backups, content, widget, callback_credential, monitoring, telemetry."
          ]}},
      environment:
        {:meta, :string,
         [
           description:
             "Required for the \"deploy\" step: which environment to deploy (e.g. \"uat\"). Deploying is a decision about one specific environment, not a batch operation — without this, `Steps.run(:deploy, …)` would deploy every environment the project has in one call, in an unspecified order, stopping at the first failure. That silently includes prod even when a caller only meant to touch uat, so this tool requires naming the one environment intended."
         ]},
      telemetry_mode:
        {:meta, :string,
         [
           description:
             "For the \"telemetry\" step only: \"full\" (the default: ClickHouse and the collector), \"capped\" (ClickHouse with a memory cap) or \"collector_only\" (only the OTLP collector; data queues locally until ClickHouse is installed). Pick capped or collector_only on a box shared with other apps."
         ]},
      inbound_probe_to:
        {:meta, :string,
         [
           description:
             "For the \"inbound\" step only: an address on the project's own domain to prove receiving works (e.g. \"sam@example.com\"). Resend accepts mail only to addresses configured for the domain, so this cannot be guessed."
         ]},
      confirm_apex_repoint:
        {:meta, :boolean,
         [
           description:
             "For the \"dns\" step only: the apex already resolves somewhere, and this run would repoint it at a server it just created — which takes down whatever is live there today. The step pauses and names the current and new address instead of doing this silently; set this to true once that repoint is actually wanted, and call the step again."
         ]},
      confirm_inbound_mx_repoint:
        {:meta, :boolean,
         [
           description:
             "For the \"inbound\" step only: the domain already has an MX record, and publishing Resend's here would replace rather than add to it — which can silently redirect or break mail that already routes through the existing one. The step pauses and names the current record instead of doing this silently; set this to true once that replacement is actually wanted, and call the step again."
         ]}
    }
  end

  @impl true
  def call(%{step: step} = params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope),
         {:ok, key} <- find_step(step),
         :ok <- require_environment(key, params) do
      starter = Starter.new(scope, context, label(step, params))

      scope
      |> Resources.project_scope(project)
      |> start_step_async(project, key, run_opts(params), starter)
      |> reply(step, project, context)
    else
      {:error, reason} -> error(reason)
    end
  end

  @doc false
  # Public for its test: each option a param carries to the step.
  def run_opts(params) do
    []
    |> with_telemetry_mode(params)
    |> with_inbound_probe(params)
    |> with_confirm_apex_repoint(params)
    |> with_confirm_inbound_mx_repoint(params)
    |> with_force(params)
    |> with_environment(params)
  end

  @telemetry_modes ~w(full capped collector_only)

  # An unknown mode is passed through as given, for `ClickHouse` to refuse by name.
  defp with_telemetry_mode(opts, params) do
    case Map.get(params, :telemetry_mode) do
      mode when mode in @telemetry_modes ->
        Keyword.put(opts, :telemetry_mode, String.to_atom(mode))

      mode when is_binary(mode) and mode != "" ->
        Keyword.put(opts, :telemetry_mode, mode)

      _ ->
        opts
    end
  end

  defp with_inbound_probe(opts, params) do
    case Map.get(params, :inbound_probe_to) do
      to when is_binary(to) and to != "" -> Keyword.put(opts, :inbound_probe_to, to)
      _ -> opts
    end
  end

  defp with_confirm_apex_repoint(opts, params) do
    case Map.get(params, :confirm_apex_repoint) do
      true -> Keyword.put(opts, :confirm_apex_repoint, true)
      _ -> opts
    end
  end

  defp with_confirm_inbound_mx_repoint(opts, params) do
    case Map.get(params, :confirm_inbound_mx_repoint) do
      true -> Keyword.put(opts, :confirm_inbound_mx_repoint, true)
      _ -> opts
    end
  end

  defp with_force(opts, params) do
    case Map.get(params, :force) do
      true -> Keyword.put(opts, :force, true)
      _ -> opts
    end
  end

  defp with_environment(opts, %{step: "dns", environment: name})
       when is_binary(name) and name != "",
       do: Keyword.put(opts, :environments, [name])

  defp with_environment(opts, params) do
    case Map.get(params, :environment) do
      environment when is_binary(environment) and environment != "" ->
        Keyword.put(opts, :environment, environment)

      _ ->
        opts
    end
  end

  defp find_step(step) do
    case Enum.find(Step.keys(), &(to_string(&1) == step)) do
      nil ->
        {:error,
         "unknown step #{inspect(step)} — must be one of #{Enum.map_join(Step.keys(), ", ", &to_string/1)}"}

      key ->
        {:ok, key}
    end
  end

  # Deploying is a decision about one environment. Without one, the step
  # deploys every environment in no defined order (prod included) and halts at
  # the first failure, so this refuses before reaching the step.
  defp require_environment(:deploy, params) do
    case Map.get(params, :environment) do
      environment when is_binary(environment) and environment != "" ->
        :ok

      _ ->
        {:error,
         "the \"deploy\" step needs :environment — name the one environment to deploy (e.g. \"uat\"), never all of them at once"}
    end
  end

  defp require_environment(_key, _params), do: :ok

  # The `:provisioning_run_async` flag `Provisioning.run_step_async/3` reads:
  # under test a spawned child holds neither the Ecto sandbox checkout nor the
  # `Req.Test` allowances, so the step runs synchronously.
  defp start_step_async(scope, project, key, opts, starter) do
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true -> spawn_step_async(scope, project, key, opts, starter)
      _ -> RunLock.with_lock(project.id, fn -> Provisioning.run_step(scope, key, opts) end)
    end
  end

  # `Resources.fix_async/3`'s handshake, for one step: the spawned task claims
  # `RunLock` first and only then signals, so the caller learns "running" or
  # "refused" in milliseconds. The step runs on under `CodeMySpec.TaskSupervisor`,
  # out of reach of this call's timeouts.
  defp spawn_step_async(scope, project, key, opts, starter) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        RunLock.with_lock(
          project.id,
          fn ->
            send(parent, {ref, :locked})
            Provisioning.run_step(scope, key, opts)
          end,
          Starter.lock_holder(starter)
        )
        |> case do
          {:error, {:already_running, _}} = refused ->
            send(parent, {ref, refused})

          finished ->
            {_scope, _agent_id, label} = starter
            Starter.tell(starter, outcome_message(finished, label, project.name))
        end
      end)

    receive do
      {^ref, :locked} -> {:ok, :started}
      {^ref, {:error, {:already_running, _}} = refused} -> refused
    after
      5_000 -> {:error, :lock_handshake_timeout}
    end
  end

  defp reply({:ok, :started}, step, project, context) do
    ok("#{step} for #{project.name} started — #{then_what(context)}")
  end

  # The synchronous (test-mode) outcomes: `Provisioning.run_step/3`'s result.
  defp reply({:ok, %{state: state} = row}, step, project, _context) do
    ok("#{step} for #{project.name} is now #{state}.#{dns_outcomes(row, step)}")
  end

  # Paused (waiting on a person) is an expected outcome, not a failure.
  defp reply({:halt, %{state: :paused}, reason}, step, project, _context) do
    ok("#{step} for #{project.name} is paused: #{reason}")
  end

  defp reply({:halt, %{state: state}, reason}, step, project, _context) do
    error("#{step} for #{project.name} is now #{state}: #{reason}")
  end

  defp reply({:error, {:already_running, started_at}}, _step, _project, _context) do
    since = started_at && " (started #{started_at})"

    error(
      "a setup run is already in progress for this project#{since} — call devops_status rather than retrying"
    )
  end

  defp reply({:error, :lock_handshake_timeout}, step, project, _context) do
    error(
      "could not confirm #{step} started for #{project.name} — check devops_status, or try again shortly"
    )
  end

  defp then_what(context), do: Starter.then_what(context[:agent_id])

  defp label(step, %{environment: env}) when is_binary(env) and env != "", do: "#{step} (#{env})"
  defp label(step, _params), do: step

  @doc false
  def outcome_message({:ok, %{state: state} = row}, label, name),
    do:
      "Your #{label} step for #{name} finished: #{state}.#{dns_outcomes(row, label)} #{answer()}"

  def outcome_message({:halt, %{state: :paused}, reason}, label, name),
    do:
      "Your #{label} step for #{name} paused: #{Truncate.head_and_tail(reason)}\n\n" <>
        "It will not continue on its own. #{answer()}"

  def outcome_message({:halt, %{state: :errored}, reason}, label, name),
    do:
      "Your #{label} step for #{name} errored: #{Truncate.head_and_tail(reason)}\n\n" <>
        "It is no longer running. #{answer()}"

  # A done step whose provider could not be read halts without demoting it.
  def outcome_message({:halt, %{state: state}, reason}, label, name),
    do:
      "Your #{label} step for #{name} stopped, still #{state}: " <>
        "#{Truncate.head_and_tail(reason)}\n\n#{answer()}"

  defp dns_outcomes(%{resources: resources}, "dns") when is_list(resources) do
    outcomes =
      resources
      |> Enum.filter(&(&1.kind == "dns_outcome"))
      |> Enum.map_join(", ", & &1.identifier)

    if outcomes == "", do: "", else: " DNS outcomes: #{outcomes}."
  end

  defp dns_outcomes(_row, _step), do: ""

  defp answer, do: "This is the outcome of the step you started — act on it now."

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not run the step: #{inspect(reason)}"}
end
