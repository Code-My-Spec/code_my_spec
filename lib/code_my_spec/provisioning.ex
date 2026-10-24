defmodule CodeMySpec.Provisioning do
  @moduledoc """
  Procedural infrastructure setup — the ordered sequence, its state, and how it
  resumes.

  Setup only. Nothing here tears anything down (see `Provisioning.Teardown`).

  - `Step` rows record what was last observed, never proof a resource exists.
    `verify/3` asks the provider every time, so a resource deleted behind
    setup's back is rebuilt rather than skipped.
  - `run/3` halts at the first step that errors or pauses and leaves the rest
    `:not_started`.
  - `resume/3` retries an `:errored` step and re-verifies a `:paused` one
    against the provider — coming back is not evidence the errand was done.

  See knowledge/provisioning, "Running the sequence".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AccountSecrets,
      CodeMySpec.AppTokens,
      CodeMySpec.AppInstances,
      CodeMySpec.Content,
      CodeMySpec.ContentPublishing,
      CodeMySpec.Conversations,
      CodeMySpec.Deploys,
      CodeMySpec.ExecutionContexts,
      CodeMySpec.Files,
      CodeMySpec.Generators,
      CodeMySpec.GitHub,
      CodeMySpec.Integrations,
      CodeMySpec.LocalScope,
      CodeMySpec.ProjectSecrets,
      CodeMySpec.Projects,
      CodeMySpec.Environments,
      CodeMySpec.ProvisioningPlan,
      CodeMySpec.Provisioning.Hetzner,
      CodeMySpec.Repo,
      CodeMySpec.Servers,
      CodeMySpec.Telemetry,
      CodeMySpec.TempFile,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies,
      CodeMySpec.Utils
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.{QaFixture, RunLock, Steps}
  alias CodeMySpec.ProvisioningPlan
  alias CodeMySpec.ProvisioningPlan.{Sequence, Step, StepRepository}

  alias CodeMySpec.Users.Scope

  @type run_result :: %{
          steps: [Step.t()],
          halted_at: atom() | nil,
          reason: String.t() | nil
        }

  # Which module backs each step. Informational only — dispatch goes through
  # `Steps.run/3`; keeping this descriptive avoids a second source of truth.
  @runners %{
    repository: CodeMySpec.Provisioning.Repository,
    server: CodeMySpec.Provisioning.Hetzner,
    domain: CodeMySpec.Provisioning.Cloudflare,
    dns: CodeMySpec.Provisioning.Cloudflare,
    email: CodeMySpec.Provisioning.Resend,
    inbound: CodeMySpec.Provisioning.Resend,
    deploy: CodeMySpec.Provisioning.Deploy,
    monitoring: CodeMySpec.Provisioning.Deploy,
    content: CodeMySpec.Provisioning.ContentPublishing,
    widget: CodeMySpec.Provisioning.Widget
  }

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @doc "The module that owns a step, or nil for steps with no provider yet."
  @spec runner(atom()) :: module() | nil
  def runner(key), do: Map.get(@runners, key)

  @doc """
  The persisted step row for `key`, or nil. `environment` is nil for a
  project-wide step and a name for one environment's row of a per-environment
  step.
  """
  @spec get_step(Scope.t(), atom(), String.t() | nil) :: Step.t() | nil
  def get_step(scope, key, environment \\ nil)

  def get_step(%Scope{} = scope, key, environment),
    do: StepRepository.get(scope, key, environment)

  @doc """
  Record a domain adopted through the check form as the domain step's
  completion.

  Adopting an existing domain is an ordinary success, so the domain step reads
  done. The resource is marked `origin: "adopted"` so teardown leaves it alone.
  """
  @spec adopt_domain_step(Scope.t(), String.t()) :: Step.t()
  def adopt_domain_step(%Scope{} = scope, name) do
    mark(scope, :domain, nil, :done, %{
      resources: [%{kind: "domain", location: "cloudflare/#{name}", origin: "adopted"}]
    })
  end

  ## Options

  @doc "Every optional part of setup. See `ProvisioningPlan.available_options/0`."
  defdelegate available_options(), to: ProvisioningPlan

  @doc "The options a project has chosen. See `ProvisioningPlan.setup_options/1`."
  defdelegate setup_options(project_or_scope), to: ProvisioningPlan

  @doc """
  Persist the project's chosen options, so a remount does not reset them.
  """
  @spec put_setup_options(Scope.t(), [atom() | String.t()]) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def put_setup_options(%Scope{active_project: %Project{} = project} = scope, options) do
    known = MapSet.new(available_options(), &to_string/1)

    stored =
      options |> Enum.map(&to_string/1) |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.uniq()

    with {:ok, _project} = updated <-
           Projects.update_project(scope, project, %{setup_options: stored}) do
      StepRepository.setup_changed(scope)
      updated
    end
  end

  ## Plan

  @doc """
  The project's deployment environments, by name.

  Callers that fan out over environments — the setup page, the steps — ask
  here rather than carrying a list. `prod` and `uat` are rows a project starts
  with, not a fixed set, so a project may have `qa` or one environment per
  story without a code change.
  """
  @spec environment_names(Scope.t()) :: [String.t()]
  def environment_names(%Scope{} = scope),
    do: Environments.deployment_names(scope)

  @doc """
  The project's environments, in full.

  `environment_names/1` answers "which are there"; this answers "and what is
  each one running on", which is the question the page has to render — an
  environment sharing another's box is invisible from the names alone.
  """
  @spec environments(Scope.t()) :: [Environment.t()]
  def environments(%Scope{} = scope),
    do: Environments.list_deployment(scope)

  @doc """
  A project's environments, seeding none.

  The read for anything that is only looking. See
  `Environments.list_existing_deployment/1`.
  """
  @spec existing_environments(Scope.t()) :: [Environment.t()]
  def existing_environments(%Scope{} = scope),
    do: Environments.list_existing_deployment(scope)

  @doc """
  Add an environment, or update one that is already there.

  The host is derived from the project's domain — prod on the apex, anything
  else on a subdomain of its own name — so a new environment is reachable
  without anyone deciding where it lives.
  """
  @spec put_environment(Scope.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def put_environment(%Scope{active_project: project} = scope, name, attrs \\ %{}) do
    domain = Map.get(project || %{}, :domain)
    host = Map.get(attrs, :host) || derived_host(name, domain)

    Environments.put_deployment(scope, name, Map.put(attrs, :host, host))
  end

  defp derived_host(_name, domain) when domain in [nil, ""], do: nil
  defp derived_host("prod", domain), do: domain
  defp derived_host(name, domain), do: "#{name}.#{domain}"

  @doc "The environment a primary-only step acts on. See `ProvisioningPlan.primary_environment/1`."
  defdelegate primary_environment(scope), to: ProvisioningPlan

  @doc "The whole plan for a project, before anything runs. See `ProvisioningPlan.plan/3`."
  defdelegate plan(scope, enabled_options, opts \\ []), to: ProvisioningPlan

  ## Running

  @doc """
  Run the sequence from the top, halting at the first step that does not
  finish.

  Each step is verified against its provider before running, so a step whose
  resource still exists converges instead of duplicating and one whose
  resource was deleted is rebuilt.
  """
  @spec run(Scope.t(), [atom()], keyword()) :: run_result()
  def run(%Scope{} = scope, enabled_options, opts \\ []) do
    enabled_options
    |> Sequence.for_options()
    |> Enum.reduce_while(%{steps: [], halted_at: nil, reason: nil}, fn step, acc ->
      case run_step(scope, step.key, opts) do
        {:ok, row} ->
          {:cont, %{acc | steps: acc.steps ++ [row]}}

        {:halt, row, reason} ->
          Logger.info("[Provisioning] halted at #{step.key}: #{reason}")

          {:halt, %{acc | steps: acc.steps ++ [row], halted_at: step.key, reason: reason}}
      end
    end)
  end

  @doc """
  Run one step, verifying against the provider first.

  Returns `{:ok, step}` when it finished, or `{:halt, step, reason}` when it
  errored or paused. Retrying one errored step without re-running the rest is
  exactly this call.

  `opts[:force]` skips verification and runs unconditionally. See
  knowledge/provisioning, "Forcing a step".
  """
  @spec run_step(Scope.t(), atom(), keyword()) ::
          {:ok, Step.t()} | {:halt, Step.t(), String.t()}
  def run_step(scope, key, opts \\ [])

  # `:content` cannot act on more than one environment's site, so it runs once,
  # against the primary environment, and its one row is attributed there.
  def run_step(%Scope{} = scope, :content = key, opts) do
    case primary_environment(scope) do
      nil -> {:ok, unsaved_step(key, nil)}
      environment -> run_step(scope, key, environment, opts)
    end
  end

  def run_step(%Scope{} = scope, key, opts) do
    case Sequence.scope(key) do
      :project ->
        run_step(scope, key, nil, opts)

      :environment ->
        case step_environments(scope, opts) do
          [] -> {:ok, unsaved_step(key, nil)}
          environments -> run_step_across(scope, key, environments, opts)
        end
    end
  end

  # `opts[:environment]` wins (the deploy form's own contract, extended
  # uniformly to every per-environment step); `opts[:environments]` narrows to
  # exactly that list; absent either, every environment the project has.
  defp step_environments(scope, opts) do
    cond do
      environment = Keyword.get(opts, :environment) -> [environment]
      environments = Keyword.get(opts, :environments) -> environments
      true -> Steps.permitted_environments(scope)
    end
  end

  # One environment at a time, halting the whole walk on the first failure.
  # Returns the last successful row, or the row that halted.
  defp run_step_across(scope, key, environments, opts) do
    Enum.reduce_while(environments, nil, fn environment, _acc ->
      case run_step(scope, key, environment, opts) do
        {:ok, row} -> {:cont, {:ok, row}}
        {:halt, row, reason} -> {:halt, {:halt, row, reason}}
      end
    end)
  end

  defp unsaved_step(key, environment) do
    %Step{
      key: key,
      environment: environment,
      state: :not_started,
      position: Sequence.position(key)
    }
  end

  @doc """
  Run one step for one environment (`nil` for a project-wide step), verifying
  against the provider first.

  Returns `{:ok, step}` when it finished, or `{:halt, step, reason}` when it
  errored or paused.

  `opts[:force]` skips verification and runs unconditionally. See
  knowledge/provisioning, "Forcing a step".
  """
  @spec run_step(Scope.t(), atom(), String.t() | nil, keyword()) ::
          {:ok, Step.t()} | {:halt, Step.t(), String.t()}
  def run_step(%Scope{} = scope, key, environment, opts) do
    opts = QaFixture.options(scope, opts, environment)
    execute = Keyword.get(opts, :execute, &execute_step/3)
    scope = reread_project(scope)
    previous = StepRepository.get(scope, key, environment)
    opts = with_environment_opt(scope, key, environment, opts)

    case forced_or_verified(scope, key, opts) do
      {:ok, :satisfied, resources} ->
        {:ok,
         mark(scope, key, environment, :done, %{
           resources: still_ours(scope, key, environment, resources),
           verified_at: DateTime.utc_now()
         })}

      {:ok, :absent} ->
        run_and_record(scope, key, environment, execute, opts)

      # A provider that could not be read is not a verdict the resource is
      # gone: halt, but keep a `:done` row `:done` so the next attempt
      # re-verifies rather than rebuilding on the strength of a timeout.
      {:error, reason} when not is_nil(previous) and previous.state == :done ->
        {:halt, previous, describe(reason)}

      {:error, reason} ->
        {:halt, mark(scope, key, environment, :errored, error_attrs(key, reason)),
         describe(reason)}
    end
  end

  # Translates a resolved environment into the opts each step's `run/3` and
  # `verify/3` read: `:deploy` takes `:environment`, `:tls` takes `:host`, the
  # rest take a one-element `:environments`.
  defp with_environment_opt(_scope, _key, nil, opts), do: opts

  defp with_environment_opt(_scope, :deploy, environment, opts),
    do: Keyword.put(opts, :environment, environment)

  defp with_environment_opt(scope, :tls, environment, opts) do
    case Enum.find(environments(scope), &(&1.name == environment)) do
      %{host: host} when is_binary(host) and host != "" -> Keyword.put(opts, :host, host)
      _ -> opts
    end
  end

  defp with_environment_opt(_scope, key, environment, opts)
       when key in [:secrets, :storage, :backups, :widget, :callback_credential],
       do: Keyword.put(opts, :environments, [environment])

  defp with_environment_opt(_scope, _key, _environment, opts), do: opts

  # `:force` reports the resource absent unconditionally, which sends the step
  # straight to `run_and_record/5`.
  defp forced_or_verified(scope, key, opts) do
    if Keyword.get(opts, :force, false), do: {:ok, :absent}, else: safe_verify(scope, key, opts)
  end

  # A verify that raises is "could not confirm", not "gone": it halts the step
  # cleanly instead of crashing the runner.
  defp safe_verify(scope, key, opts) do
    verify(scope, key, opts)
  rescue
    error ->
      Logger.error(Exception.format(:error, error, __STACKTRACE__))
      {:error, Exception.message(error)}
  end

  @doc """
  Run a step without waiting for it.

  Steps such as a deploy take minutes. Under a supervised task a client that
  disconnects does not take the run with it. Returns immediately; `mark/5`
  broadcasts every transition, so `subscribe/1` sees the step move through
  `running` to whatever it becomes.
  """
  @spec run_step_async(Scope.t(), atom(), keyword()) :: :ok
  def run_step_async(%Scope{} = scope, key, opts \\ []) do
    # Synchronous when `:provisioning_run_async` is false (test): a detached
    # task would outlive the test and its sandbox connection. Transitions are
    # broadcast either way.
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true -> spawn_step(scope, key, opts)
      _ -> run_step_sync(scope, key, opts)
    end
  end

  @doc "A run currently in flight for this project's `RunLock`, right now?"
  @spec runs_in_flight?(Scope.t()) :: boolean()
  def runs_in_flight?(%Scope{active_project_id: project_id}) when is_binary(project_id),
    do: not is_nil(RunLock.in_flight(project_id))

  def runs_in_flight?(_scope), do: false

  @doc """
  Block until this project's `RunLock` is free, or `opts[:timeout]` elapses.

  `run_provisioning_step`/`run_devops_setup` return the moment a run starts,
  because the MCP request cap and code-mode's 30s wall clock are far shorter
  than a real run. A caller that wants to wait polls `RunLock` here. Run it
  outside code-mode; `RunLock` is a `Registry`, not a broadcaster, so this
  polls.
  """
  @spec await_run(Scope.t(), keyword()) :: :ok | :timeout
  def await_run(%Scope{} = scope, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_free(scope, deadline)
  end

  defp poll_until_free(scope, deadline) do
    cond do
      not runs_in_flight?(scope) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(500)
        poll_until_free(scope, deadline)
    end
  end

  defp spawn_step(%Scope{active_project_id: project_id} = scope, key, opts) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        run_locked_step(scope, project_id, key, opts)
      end)

    :ok
  end

  # Same `RunLock` as a whole-sequence run. A refused single-step run is only
  # logged: the button never awaited a result, so there is no caller to tell.
  defp run_locked_step(scope, project_id, key, opts) do
    case RunLock.with_lock(project_id, fn -> run_step(scope, key, opts) end) do
      {:error, {:already_running, started_at}} ->
        Logger.info(
          "[Provisioning] #{key} skipped — a run for this project is already in flight" <>
            ((started_at && " (started #{started_at})") || "")
        )

      result ->
        announce(scope, {:provisioning, :finished, result})
        :ok
    end
  end

  defp run_step_sync(scope, key, opts) do
    _result = run_step(scope, key, opts)
    :ok
  end

  defp run_and_record(scope, key, environment, execute, opts) do
    # Stamped when the step actually begins, not when the row is created.
    _ = mark(scope, key, environment, :running, %{started_at: DateTime.utc_now()})

    execute_and_record(scope, key, environment, execute, opts)
  rescue
    # A step that raises halts as an errored step rather than crashing the
    # runner and leaving its row `:running` forever. The stacktrace is logged;
    # the row stores only the message.
    error ->
      reason = Exception.message(error)
      Logger.error(Exception.format(:error, error, __STACKTRACE__))
      row = mark(scope, key, environment, :errored, error_attrs(key, reason))
      {:halt, row, reason}
  end

  defp execute_and_record(scope, key, environment, execute, opts) do
    case execute.(scope, key, opts) do
      # Merge with what earlier runs recorded.
      # See knowledge/provisioning, "Resource records".
      {:ok, resources} ->
        {:ok,
         mark(scope, key, environment, :done, %{
           resources: keeping_earlier(scope, key, environment, resources)
         })}

      {:paused, instructions} ->
        row = mark(scope, key, environment, :paused, %{paused_instructions: instructions})
        {:halt, row, instructions}

      # A pause carries resources too: a step can create something real and
      # then wait (the email step registers a domain, then pauses to verify).
      {:paused, instructions, partial} when is_list(partial) ->
        row =
          mark(scope, key, environment, :paused, %{
            paused_instructions: instructions,
            resources: keeping_earlier(scope, key, environment, partial)
          })

        {:halt, row, instructions}

      # A step that got partway records what it made before it failed;
      # teardown works only from recorded resources.
      {:error, reason, partial} when is_list(partial) ->
        row =
          mark(
            scope,
            key,
            environment,
            :errored,
            Map.put(
              error_attrs(key, reason),
              :resources,
              keeping_earlier(scope, key, environment, partial)
            )
          )

        {:halt, row, describe(reason)}

      {:error, reason} ->
        row = mark(scope, key, environment, :errored, error_attrs(key, reason))
        {:halt, row, describe(reason)}
    end
  end

  @doc """
  Send a message to an address on the project's domain and wait for it to
  arrive.

  The inbound step proves itself the same way; this is the button that does it
  on demand, because a domain that stops receiving looks exactly like one that
  never did until somebody sends to it.

  Returns the received message, so the caller can say *where* it landed rather
  than only that the provider accepted it.
  """
  @spec probe_inbound(Scope.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def probe_inbound(%Scope{} = scope, to, opts \\ []) do
    Steps.probe_inbound(scope, to, opts)
  end

  @doc """
  Whether a step's resource actually exists right now, according to its
  provider.

  Never reads the persisted state to answer this. A `:done` row is a claim
  about the past.
  """
  @spec verify(Scope.t(), atom(), keyword()) ::
          {:ok, :satisfied, [map()]} | {:ok, :absent} | {:error, term()}
  def verify(%Scope{} = scope, key, opts \\ []) do
    opts = QaFixture.options(scope, opts)

    case Keyword.get(opts, :verify) do
      nil -> Steps.verify(key, scope, opts)
      verifier -> verifier.(scope, key)
    end
  end

  @doc """
  Watch a project's setup as it runs.
  Watch a project's setup as it runs: `{:provisioning, :step, row}` on every
  transition and `{:provisioning, :finished, result}` at the end.
  """
  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{active_project_id: id}) when is_binary(id),
    do: Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(id))

  def subscribe(_scope), do: :ok

  defp topic(project_id), do: "provisioning:#{project_id}"

  defp announce(%Scope{active_project_id: id}, message) when is_binary(id),
    do: Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(id), message)

  defp announce(_scope, _message), do: :ok

  @doc """
  Start the sequence in the background and return immediately.

  The caller gets `{:ok, pid}` and then `{:provisioning, :step, row}` messages
  as each step changes, so a step visibly moves to `running` while the page is
  open. Providers are slow; this keeps a LiveView process free.
  """
  @spec run_async(Scope.t(), [atom()], keyword()) :: {:ok, pid() | :sync}
  def run_async(%Scope{} = scope, enabled_options, opts \\ []) do
    if Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      spawn_run(scope, enabled_options, opts)
    else
      # Synchronously under test, so the run shares the ExUnit sandbox
      # connection. Transitions are still broadcast.
      result = run(scope, enabled_options, opts)
      announce(scope, {:provisioning, :finished, result})
      {:ok, :sync}
    end
  end

  defp spawn_run(%Scope{active_project_id: project_id} = scope, enabled_options, opts) do
    {:ok, pid} =
      Task.start(fn ->
        run_locked(project_id, scope, "start_setup", fn ->
          run_or_rescue(scope, enabled_options, opts)
        end)
      end)

    {:ok, pid}
  end

  # The caller is subscribed to the topic, not linked to this task, so a step
  # that raises must not take the page down with it — it is reported like any
  # other failure.
  defp run_or_rescue(scope, enabled_options, opts) do
    run(scope, enabled_options, opts)
  rescue
    error -> %{steps: [], halted_at: :unknown, reason: Exception.message(error)}
  end

  # Under the same `RunLock` as a single-step retry, so start, resume and a
  # per-step Run/Retry cannot write the same project's rows at once. The caller
  # already subscribed, so the broadcast is the only delivery.
  defp run_locked(project_id, scope, label, fun) do
    case RunLock.with_lock(project_id, fun) do
      {:error, {:already_running, _}} ->
        Logger.info(
          "[Provisioning] #{label} skipped — a run for this project is already in flight"
        )

      result ->
        announce(scope, {:provisioning, :finished, result})
    end
  end

  @doc """
  Re-check every step that claims to be done, against its provider.

  A persisted row says what was observed once, so opening the page asks the
  providers, and a step whose resource has gone drops to `:not_started` so the
  next run rebuilds it.

  Only `:done` steps are checked. Failures leave the row alone: an unreachable
  provider is not evidence the resource is gone.
  """
  @spec reverify(Scope.t(), [atom()], keyword()) :: :ok
  def reverify(%Scope{} = scope, enabled_options, opts \\ []) do
    now = DateTime.utc_now()
    names = Steps.permitted_environments(scope)

    for step <- Sequence.for_options(enabled_options),
        environment <- ProvisioningPlan.step_environments(names, step),
        row = StepRepository.get(scope, step.key, environment),
        row && row.state == :done do
      verify_opts = with_environment_opt(scope, step.key, environment, opts)

      case safe_verify(scope, step.key, verify_opts) do
        {:ok, :satisfied, resources} ->
          mark(scope, step.key, environment, :done, %{
            resources:
              Enum.map(resources, fn resource ->
                resource |> resource_attrs() |> Map.put(:observed_in_latest_run, true)
              end),
            verified_at: now
          })

        {:ok, :absent} ->
          # State only — the recorded resources stay. `:absent` can mean a
          # partial setup, and teardown removes only what a step recorded.
          Logger.info("[Provisioning] #{step.key} no longer verifies — marking not_started")
          mark(scope, step.key, environment, :not_started, %{verified_at: now})

        {:error, _reason} ->
          :unreachable
      end
    end

    :ok
  end

  ## Resuming

  @doc """
  Continue a stopped run.

  A paused step is re-verified rather than assumed complete; an errored step
  is retried. The run continues from the first step not fully done, so steps
  that already succeeded are not re-executed.
  """
  @spec resume(Scope.t(), [atom()], keyword()) :: run_result()
  def resume(%Scope{} = scope, enabled_options, opts \\ []) do
    steps = Sequence.for_options(enabled_options)
    persisted = StepRepository.list(scope)

    remaining = Enum.drop_while(steps, &step_fully_done?(&1, persisted, scope))

    Enum.reduce_while(remaining, %{steps: [], halted_at: nil, reason: nil}, fn step, acc ->
      case run_step(scope, step.key, opts) do
        {:ok, row} ->
          {:cont, %{acc | steps: acc.steps ++ [row]}}

        {:halt, row, reason} ->
          {:halt, %{acc | steps: acc.steps ++ [row], halted_at: step.key, reason: reason}}
      end
    end)
  end

  @doc """
  Continue a stopped run in the background and return immediately.

  Started, not awaited, under the same `RunLock` as `run_async/3` and a
  single-step retry.
  """
  @spec resume_async(Scope.t(), [atom()], keyword()) :: :ok
  def resume_async(%Scope{} = scope, enabled_options, opts \\ []) do
    if Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      spawn_resume(scope, enabled_options, opts)
    else
      # Synchronous under test, for the same reason run_async/3 is.
      result = resume(scope, enabled_options, opts)
      announce(scope, {:provisioning, :finished, result})
    end

    :ok
  end

  defp spawn_resume(%Scope{active_project_id: project_id} = scope, enabled_options, opts) do
    Task.start(fn ->
      run_locked(project_id, scope, "resume_setup", fn -> resume(scope, enabled_options, opts) end)
    end)

    :ok
  end

  defp done?(%Step{state: :done}), do: true
  defp done?(_), do: false

  # A project-wide step is done when its one row is; `:content` when its
  # primary-environment row is; any other per-environment step when every
  # environment's row is. Only used to skip calls — `run_step/4`'s verify
  # decides, so under-skipping costs a redundant verify, never a wrong result.
  defp step_fully_done?(%{key: :content}, persisted, scope) do
    environment = primary_environment(scope)
    persisted |> Enum.find(&(&1.key == :content and &1.environment == environment)) |> done?()
  end

  defp step_fully_done?(%{key: key, scope: :project}, persisted, _scope) do
    persisted |> Enum.find(&(&1.key == key and is_nil(&1.environment))) |> done?()
  end

  defp step_fully_done?(%{key: key, scope: :environment}, persisted, scope) do
    case Steps.permitted_environments(scope) do
      [] ->
        false

      names ->
        Enum.all?(names, fn name ->
          persisted |> Enum.find(&(&1.key == key and &1.environment == name)) |> done?()
        end)
    end
  end

  ## Escalation

  @doc """
  What the setup agent is handed when a step fails.

  Carries the step, what it attempted, and the provider's own words — the
  detail that names e.g. a missing token permission is what a summary drops.
  """
  @spec escalation(Step.t()) :: map()
  def escalation(%Step{} = step) do
    %{
      step: step.key,
      attempted: step.attempted,
      provider_error: step.provider_error,
      state: step.state
    }
  end

  ## Internals

  defp execute_step(scope, key, opts), do: Steps.run(key, scope, opts)

  # The project as it is now, not as it was when the run started: one step
  # writes fields a later step reads (the secrets step mints `deploy_key`, the
  # widget step reads it), and the scope was built once for the whole run.
  defp reread_project(%Scope{active_project: %{id: id}} = scope) when not is_nil(id) do
    case Projects.get_project(scope, id) do
      {:ok, project} -> %{scope | active_project: project}
      {:error, :not_found} -> scope
    end
  end

  defp reread_project(scope), do: scope

  defp error_attrs(key, reason) do
    %{
      attempted: "run the #{key} step",
      provider_error: describe(reason)
    }
  end

  # Providers report failures as tuples ({:cloudflare_error, 403, body}), which
  # `to_string/1` raises on.
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: to_string(reason)

  # No `inspect` truncation: long errors are build logs, whose cause is the
  # last line.
  defp describe(reason), do: inspect(reason, printable_limit: :infinity, limit: :infinity)

  # Kinds that describe what the latest run did (phases, live version, failure);
  # a later run's answer supersedes an earlier one rather than merging.
  # See knowledge/provisioning, "Resource records".
  @run_scoped ~w(deploy_phase live_version deploy_failure)

  defp keeping_earlier(scope, key, environment, partial) do
    earlier =
      case StepRepository.get(scope, key, environment) do
        %{resources: resources} when is_list(resources) -> resources
        _ -> []
      end
      |> Enum.reject(&(&1.kind in @run_scoped))

    origins = Map.new(earlier, &{{&1.kind, &1.location}, &1.origin})
    made_this_run = MapSet.new(partial, &{&1[:kind], &1[:location]})

    refreshed =
      Enum.map(partial, fn resource ->
        case Map.fetch(origins, {resource[:kind], resource[:location]}) do
          {:ok, origin} -> Map.put(resource, :origin, origin)
          :error -> resource
        end
      end)

    earlier
    |> Enum.reject(&MapSet.member?(made_this_run, {&1.kind, &1.location}))
    |> Enum.map(fn resource ->
      resource |> Map.from_struct() |> Map.put(:observed_in_latest_run, false)
    end)
    |> Enum.concat(Enum.map(refreshed, &Map.put(&1, :observed_in_latest_run, true)))
  end

  # Verify's list overrules what was recorded, except `origin`: earlier
  # ownership wins in both directions.
  # See knowledge/provisioning, "Resource records".
  defp still_ours(scope, key, environment, resources) do
    ours =
      case StepRepository.get(scope, key, environment) do
        %{resources: earlier} when is_list(earlier) ->
          for r <- earlier, into: %{}, do: {{r.kind, r.location}, r.origin}

        _ ->
          %{}
      end

    Enum.map(resources, fn resource ->
      resource = resource |> resource_attrs() |> Map.put(:observed_in_latest_run, true)

      case Map.fetch(ours, {field(resource, :kind), field(resource, :location)}) do
        {:ok, origin} -> Map.put(resource, :origin, origin)
        :error -> resource
      end
    end)
  end

  # `verify/3` returns `%Resource{}` structs from some steps (`:inbound`), which
  # do not implement Access.
  defp field(resource, key), do: Map.get(resource, key)

  defp resource_attrs(%_{} = resource), do: Map.from_struct(resource)
  defp resource_attrs(resource) when is_map(resource), do: resource

  defp mark(scope, key, environment, state, attrs) do
    previous = StepRepository.get(scope, key, environment)

    row =
      StepRepository.upsert(
        scope,
        key,
        environment,
        Map.merge(attrs, %{state: state, position: Sequence.position(key)})
      )

    # Announced on a state change or a new verification time; graph
    # invalidation stays state-based in StepRepository.
    if is_nil(previous) or previous.state != row.state or
         previous.verified_at != row.verified_at do
      announce(scope, {:provisioning, :step, row})
    end

    if row.state == :errored do
      :telemetry.execute([:code_my_spec, :provisioning, :failed], %{}, %{scope: scope, step: row})
    end

    row
  end
end
