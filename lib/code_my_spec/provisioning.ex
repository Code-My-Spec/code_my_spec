defmodule CodeMySpec.Provisioning do
  @moduledoc """
  Procedural infrastructure setup — the ordered sequence, its state, and how it
  resumes.

  Setup only. Nothing here tears anything down: a routine that can destroy is
  a routine nobody runs unattended, and the agent path exists for repair.

  ## Persisted state is a record, not the truth

  `Step` rows say what was last observed. They are never read as proof that a
  resource still exists. `verify/3` asks the provider, every time (criterion
  7970), which is what makes a resource deleted behind setup's back get rebuilt
  rather than skipped (criterion 7964).

  This is why `run/3` verifies before it runs rather than filtering on
  `state == :done`. Filtering on the row would make a stale row permanent: the
  step is skipped because it says done, and nothing ever re-checks.

  ## Halting is the point

  `run/3` stops at the first step that does not succeed and leaves the rest
  `:not_started` (criterion 7961). Pressing on builds later steps on a broken
  foundation — a deploy against a domain that was never registered — and the
  eventual failure surfaces nowhere near its cause.

  A step that pauses halts the run the same way. Pausing is not failure, but
  it is not progress either, and the steps after it still depend on it.

  ## Errored and paused resume differently

  Both leave the run stopped, and conflating them produces the wrong prompt:

  - `:errored` — the provider refused. `resume/2` retries the step, because
    the fix was ours or the agent's.
  - `:paused` — Sam has an errand elsewhere. `resume/2` **re-verifies against
    the provider** rather than assuming his return means he did it (criterion
    7967). Coming back is not evidence.
  """

  require Logger

  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.{
    Environment,
    EnvironmentRepository,
    Sequence,
    Step,
    StepRepository,
    Steps
  }
  alias CodeMySpec.Users.Scope

  @type run_result :: %{
          steps: [Step.t()],
          halted_at: atom() | nil,
          reason: String.t() | nil
        }

  # Which module backs each step. Informational only — dispatch goes through
  # Steps.run/3, which pattern-matches on the key. An earlier version of this
  # map WAS the wiring, and the executor ignored it: the map said every step
  # had a runner while execute_step returned "not wired" for all of them.
  # Keeping it purely descriptive avoids a second source of truth that can
  # disagree with the one that runs.
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

  @doc "The module that owns a step, or nil for steps with no provider yet."
  @spec runner(atom()) :: module() | nil
  def runner(key), do: Map.get(@runners, key)

  @doc "The persisted step row for `key`, or nil."
  @spec get_step(Scope.t(), atom()) :: Step.t() | nil
  def get_step(%Scope{} = scope, key), do: StepRepository.get(scope, key)

  @doc """
  Record a domain adopted through the check form as the domain step's
  completion.

  Adopting an existing domain is an ordinary success (criterion 8052), so the
  domain step should read done — not stay `:not_started` because the *step*
  was never run. The resource is marked `origin: "adopted"` so teardown leaves
  it alone: setup found the domain, it did not create it.
  """
  @spec adopt_domain_step(Scope.t(), String.t()) :: Step.t()
  def adopt_domain_step(%Scope{} = scope, name) do
    mark(scope, :domain, :done, %{
      resources: [%{kind: "domain", location: "cloudflare/#{name}", origin: "adopted"}]
    })
  end

  ## Options

  @doc """
  Every optional part of setup, as atoms.

  Derived from the sequence rather than listed separately, so adding a step
  with a new option cannot leave the toggle behind.
  """
  @spec available_options() :: [atom()]
  def available_options do
    Sequence.all() |> Enum.map(& &1.option) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @doc """
  The options a project has chosen.

  A project that has never chosen gets everything. Setup's job is a working
  project, and a user who wants less turns it off rather than having to
  discover what to turn on.

  `nil` and `[]` are deliberately different: `nil` is "never chosen" and
  yields the full set, `[]` is "chose none of the optional parts" and yields
  none. Collapsing them would make turning everything off indistinguishable
  from never having opened the page — and the page would helpfully turn it all
  back on.
  """
  @spec setup_options(Project.t() | Scope.t()) :: [atom()]
  def setup_options(%Scope{active_project: project}), do: setup_options(project)
  def setup_options(%Project{setup_options: nil}), do: available_options()

  def setup_options(%Project{setup_options: stored}) do
    available = available_options()
    by_name = Map.new(available, &{to_string(&1), &1})

    # Looked up rather than `String.to_existing_atom/1`: a stored option whose
    # step was later removed should be ignored, not raise. The row outlives the
    # code that wrote it.
    stored |> Enum.flat_map(&List.wrap(Map.get(by_name, &1))) |> Enum.uniq()
  end

  def setup_options(_), do: available_options()

  @doc """
  Persist the project's chosen options.

  They used to live in the LiveView socket alone, which meant every mount
  reset them: Sam turned object storage off, came back, and found it on — then
  started a run that was not the one he configured.
  """
  @spec put_setup_options(Scope.t(), [atom() | String.t()]) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def put_setup_options(%Scope{active_project: %Project{} = project} = scope, options) do
    known = MapSet.new(available_options(), &to_string/1)
    stored = options |> Enum.map(&to_string/1) |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.uniq()

    Projects.update_project(scope, project, %{setup_options: stored})
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
    do: EnvironmentRepository.names(scope)

  @doc """
  The project's environments, in full.

  `environment_names/1` answers "which are there"; this answers "and what is
  each one running on", which is the question the page has to render — an
  environment sharing another's box is invisible from the names alone.
  """
  @spec environments(Scope.t()) :: [Environment.t()]
  def environments(%Scope{} = scope),
    do: EnvironmentRepository.list(scope)

  @doc """
  A project's environments, seeding none.

  The read for anything that is only looking. See
  `EnvironmentRepository.list_existing/1`.
  """
  @spec existing_environments(Scope.t()) :: [Environment.t()]
  def existing_environments(%Scope{} = scope),
    do: EnvironmentRepository.list_existing(scope)

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

    EnvironmentRepository.put(scope, name, Map.put(attrs, :host, host))
  end

  defp derived_host(_name, domain) when domain in [nil, ""], do: nil
  defp derived_host("prod", domain), do: domain
  defp derived_host(name, domain), do: "#{name}.#{domain}"

  @doc """
  The whole plan for a project, in order, before anything runs.

  Every step carries its current state, so Sam sees the shape of the run and
  where it stands at once (criterion 7959). Steps his options exclude are
  absent, not present-and-skipped (criterion 7968).
  """
  @spec plan(Scope.t(), [atom()]) :: [map()]
  def plan(%Scope{} = scope, enabled_options) do
    persisted = scope |> StepRepository.list() |> Map.new(&{&1.key, &1})

    enabled_options
    |> Sequence.for_options()
    |> Enum.map(&entry(&1, Map.get(persisted, &1.key)))
  end

  # Two heads rather than a `row && row.field` for each of ten fields. Those
  # guards were the same question asked ten times, and asking it once — has
  # this step ever run — is both shorter and the actual distinction.
  defp entry(step, nil) do
    %{
      key: step.key,
      label: step.label,
      why: step.why,
      position: Sequence.position(step.key),
      state: :not_started,
      attempted: nil,
      provider_error: nil,
      paused_instructions: nil,
      completed_at: nil,
      started_at: nil,
      verified_at: nil,
      resources: []
    }
  end

  defp entry(step, row) do
    %{
      key: step.key,
      label: step.label,
      why: step.why,
      position: Sequence.position(step.key),
      state: row.state || :not_started,
      attempted: row.attempted,
      provider_error: row.provider_error,
      paused_instructions: row.paused_instructions,
      # When the step last changed state. A `done` row's timestamp is when it
      # finished, which is what makes "setup waited for verification rather
      # than declaring victory first" checkable rather than asserted.
      completed_at: row.updated_at,
      started_at: row.started_at,
      verified_at: row.verified_at,
      resources: row.resources || []
    }
  end

  ## Running

  @doc """
  Run the sequence from the top, halting at the first step that does not
  finish.

  Each step is verified against its provider before running, so a step whose
  resource still exists converges instead of duplicating (criterion 7965) and
  one whose resource was deleted is rebuilt (criterion 7964).
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
  exactly this call (criterion 7971).
  """
  @spec run_step(Scope.t(), atom(), keyword()) ::
          {:ok, Step.t()} | {:halt, Step.t(), String.t()}
  def run_step(%Scope{} = scope, key, opts \\ []) do
    execute = Keyword.get(opts, :execute, &execute_step/3)
    scope = reread_project(scope)

    case verify(scope, key, opts) do
      {:ok, :satisfied, resources} ->
        {:ok, mark(scope, key, :done, %{resources: still_ours(scope, key, resources)})}

      {:ok, :absent} ->
        run_and_record(scope, key, execute, opts)

      {:error, reason} ->
        {:halt, mark(scope, key, :errored, error_attrs(key, reason)), describe(reason)}
    end
  end

  @doc """
  Run a step without waiting for it.

  A deploy provisions a builder, builds a release image, pushes it, and then
  runs kamal, which pulls on the host and starts containers. That is minutes.
  It used to happen inside a LiveView `handle_event`, which is survivable only
  while the step does nothing: once the deploy step worked, a drill's
  `render_click` blocked for 1203 seconds before the client gave up, and no
  socket or proxy in front of one survives that.

  Worse, the work died with the caller. `Builder.build/3` destroys its box
  either way — proven against real build failures — but not when the process
  running it is killed, which is exactly what a client timeout does. A builder
  was left running on the account that way, attributable to no project and
  invisible to the leak audit.

  Under a supervised task, a client that disconnects no longer takes the run
  with it, and `destroy` runs.

  Returns immediately. The caller follows the same way anything else does:
  `mark/3` broadcasts every transition, so `subscribe/1` sees the step move
  through `running` to whatever it becomes. The `Step` row is the state; this
  just stops the caller having to hold the connection open to watch it.
  """
  @spec run_step_async(Scope.t(), atom(), keyword()) :: :ok
  def run_step_async(%Scope{} = scope, key, opts \\ []) do
    # The same `:provisioning_run_async` flag `run_async/3` reads, for the same
    # reason — and it was missed here when the single-step button stopped
    # awaiting.
    #
    # A detached task under test outlives the test that started it. Every
    # criterion that clicks one step and asserts on the html `render_click`
    # returns was reading a page where the step was still `not_started`, and
    # recording one was worse: the task outlived the cassette session and the
    # run died with `shared session Agent is not alive`, leaving a truncated
    # cassette behind. 966's went from 135KB to 36KB that way.
    #
    # Synchronous under test shares the ExUnit sandbox connection instead of
    # racing the test's lifetime. Transitions are still broadcast either way,
    # so a spex that polls the page still sees each state.
    case Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      true -> spawn_step(scope, key, opts)
      _ -> run_step_sync(scope, key, opts)
    end
  end

  defp spawn_step(scope, key, opts) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        run_step(scope, key, opts)
      end)

    :ok
  end

  defp run_step_sync(scope, key, opts) do
    _result = run_step(scope, key, opts)
    :ok
  end

  defp run_and_record(scope, key, execute, opts) do
    # Stamped when the step actually begins, not when the row is created — a
    # step that was never run has no start, and an ordering comparison against
    # a row's insertion time would answer for steps that never ran.
    _ = mark(scope, key, :running, %{started_at: DateTime.utc_now()})

    execute_and_record(scope, key, execute, opts)
  rescue
    # A step that raises must halt the run as an errored step, not crash the
    # runner and leave itself stuck :running. A provider client that throws, a
    # missing binary, a shell-out that blows up — all of them should stop the
    # sequence and name themselves, which is what every returned error already
    # does. Without this, the step's row stays :running forever and anything
    # watching the page waits on a run that is already dead.
    error ->
      reason = Exception.message(error)
      row = mark(scope, key, :errored, error_attrs(key, reason))
      {:halt, row, reason}
  end

  defp execute_and_record(scope, key, execute, opts) do
    case execute.(scope, key, opts) do
      # Succeeding does not make this run's list the whole truth either. A
      # second run that adds production returns production's server, and
      # replacing on success dropped UAT's — teardown then deleted the box it
      # could still see and left the other one running. That is the leak this
      # merge was written for, observed twice: once through the error path, and
      # again here after the error path was fixed.
      {:ok, resources} ->
        {:ok, mark(scope, key, :done, %{resources: keeping_earlier(scope, key, resources)})}

      {:paused, instructions} ->
        row = mark(scope, key, :paused, %{paused_instructions: instructions})
        {:halt, row, instructions}

      # Pausing carries resources for the same reason failing does. A step can
      # create something real and then stop to wait — the email step registers
      # a sending domain at Resend and pauses while it verifies — and a pause
      # that dropped the resources would leak exactly like an error that did.
      {:paused, instructions, partial} when is_list(partial) ->
        row =
          mark(scope, key, :paused, %{
            paused_instructions: instructions,
            resources: keeping_earlier(scope, key, partial)
          })

        {:halt, row, instructions}

      # A step that got partway records what it made before it failed.
      # Without this the resources are real and unrecorded, which is the
      # worst combination: nothing can find them to clean up, and nothing
      # knows they exist to bill for. Teardown works from what a step
      # recorded, so a failure that records nothing leaks by construction.
      {:error, reason, partial} when is_list(partial) ->
        row =
          mark(
            scope,
            key,
            :errored,
            Map.put(error_attrs(key, reason), :resources, keeping_earlier(scope, key, partial))
          )

        {:halt, row, describe(reason)}

      {:error, reason} ->
        row = mark(scope, key, :errored, error_attrs(key, reason))
        {:halt, row, describe(reason)}
    end
  end

  @doc """
  Send a message to an address on the project's domain and wait for it to
  arrive.

  The inbound step proves itself the same way; this is the button that does it
  on demand, because a domain that stops receiving looks exactly like one that
  never did until somebody sends to it (974/8030).

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
    case Keyword.get(opts, :verify) do
      nil -> Steps.verify(key, scope, opts)
      verifier -> verifier.(scope, key)
    end
  end

  @doc """
  Watch a project's setup as it runs.

  Story 963 is called "setup runs as a routine I can watch", and watching is
  only possible if something is published while the run is still going. A
  synchronous run that returns its whole result at the end is a routine you
  wait for, not one you watch.
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
  as each step changes — which is what makes a step visibly move to `running`
  while the page is open, rather than the whole run landing at once when it
  finishes (criteria 7960 and 7972).

  Running it in a task rather than inline also means a step that takes two
  minutes does not hold a LiveView's process hostage for two minutes; setup
  steps talk to providers, and providers are slow.
  """
  @spec run_async(Scope.t(), [atom()], keyword()) :: {:ok, pid() | :sync}
  def run_async(%Scope{} = scope, enabled_options, opts \\ []) do
    if Application.get_env(:code_my_spec, :provisioning_run_async, true) do
      spawn_run(scope, enabled_options, opts)
    else
      # Synchronously under test, so the run shares the ExUnit sandbox
      # connection instead of a detached task racing the test's lifetime —
      # the same reason content pull runs inline in test. The transitions are
      # still broadcast, so a spex that polls the page after the run sees the
      # final state. The two criteria that assert a step is *mid-run* opt back
      # into async explicitly.
      result = run(scope, enabled_options, opts)
      announce(scope, {:provisioning, :finished, result})
      {:ok, :sync}
    end
  end

  defp spawn_run(scope, enabled_options, opts) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        # The caller is subscribed to the topic, not linked to this task, so a
        # step that raises must not take the page down with it — it is
        # reported like any other failure.
        result =
          try do
            run(scope, enabled_options, opts)
          rescue
            error -> %{steps: [], halted_at: :unknown, reason: Exception.message(error)}
          end

        announce(scope, {:provisioning, :finished, result})
        send(parent, {:provisioning, :finished, result})
      end)

    {:ok, pid}
  end

  @doc """
  Re-check every step that claims to be done, against its provider.

  A persisted row says what was observed once. It is not evidence the resource
  still exists — somebody deletes a server in the console, and the row goes on
  saying done forever. So opening the page asks the providers rather than
  reading the rows back (criterion 7970), and a step whose resource has gone
  drops to `:not_started` so the next run rebuilds it rather than skipping it
  (criterion 7964).

  Only `:done` steps are checked. A step that errored or never ran has nothing
  to confirm, and asking would be a provider call per page load for no answer.

  Failures leave the row alone. A provider being unreachable is not evidence
  the resource is gone, and treating it as such would rebuild live
  infrastructure on the strength of a timeout.
  """
  @spec reverify(Scope.t(), [atom()], keyword()) :: :ok
  def reverify(%Scope{} = scope, enabled_options, opts \\ []) do
    now = DateTime.utc_now()

    for step <- Sequence.for_options(enabled_options),
        row = StepRepository.get(scope, step.key),
        row && row.state == :done do
      case verify(scope, step.key, opts) do
        {:ok, :satisfied, resources} ->
          mark(scope, step.key, :done, %{resources: resources, verified_at: now})

        {:ok, :absent} ->
          # State only — the recorded resources stay. `:absent` can mean a
          # partial setup as easily as a deleted one (the storage step reports
          # absent when one of two buckets is missing), and clearing the list
          # would lose the record of what *was* made. Teardown removes only
          # what a step recorded, so wiping that leaks whatever is still there.
          Logger.info("[Provisioning] #{step.key} no longer verifies — marking not_started")
          mark(scope, step.key, :not_started, %{verified_at: now})

        {:error, _reason} ->
          :unreachable
      end
    end

    :ok
  end

  ## Resuming

  @doc """
  Continue a stopped run.

  A paused step is re-verified rather than assumed complete — Sam returning is
  not evidence he did the errand (criterion 7967). An errored step is simply
  retried. Either way the run continues from there rather than from the top,
  so steps that already succeeded are not re-executed (criterion 7963).
  """
  @spec resume(Scope.t(), [atom()], keyword()) :: run_result()
  def resume(%Scope{} = scope, enabled_options, opts \\ []) do
    steps = Sequence.for_options(enabled_options)
    persisted = scope |> StepRepository.list() |> Map.new(&{&1.key, &1})

    remaining = Enum.drop_while(steps, fn step -> done?(Map.get(persisted, step.key)) end)

    Enum.reduce_while(remaining, %{steps: [], halted_at: nil, reason: nil}, fn step, acc ->
      case run_step(scope, step.key, opts) do
        {:ok, row} -> {:cont, %{acc | steps: acc.steps ++ [row]}}
        {:halt, row, reason} -> {:halt, %{acc | steps: acc.steps ++ [row], halted_at: step.key, reason: reason}}
      end
    end)
  end

  defp done?(%Step{state: :done}), do: true
  defp done?(_), do: false

  ## Escalation

  @doc """
  What the setup agent is handed when a step fails.

  Carries the step, what it attempted, and the provider's own words — a
  generic "the domain step failed" tells the agent nothing it can act on, and
  the detail that names which token permission is missing is exactly the
  detail a summary drops (criterion 7962).
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

  # The project as it is now, not as it was when the run started.
  #
  # Steps read the project through `scope.active_project`, and the scope is
  # built once for the whole run (`Resources.fix/2`, `ProvisioningLive`). So a
  # field one step writes is invisible to every step after it — the write lands
  # in the database and the run goes on reading a struct from before it.
  #
  # That is not hypothetical, and it is not only a drill artifact: the secrets
  # step mints `deploy_key` at position three and the widget step reads it at
  # thirteen, so a single run minted a key, stored it, and then failed with "the
  # widget step needs a deploy key, and this project has none set". `dns` writes
  # `client_api_url` at five and `content` reads it at twelve, with the same
  # result. Both looked like the writes were not happening.
  #
  # Re-read per step rather than threaded through the reduce, because `resume/3`
  # and the single-step retry button both call this directly and would each need
  # their own copy of the threading. One query per step, against a row the step
  # is about to act on.
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

  # Providers report failures as tuples far more often than as strings —
  # {:cloudflare_error, 403, body}, {:not_implemented, :backups}. `to_string/1`
  # raises on those, so the halt path crashed on the most common error shape
  # instead of recording it. Found by a test that let a real provider fail
  # rather than injecting a string.
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: to_string(reason)

  # Not the default `inspect/1`. It cuts a binary at 4096 characters and
  # appends `<> ...`, and the errors that get anywhere near that length are
  # build logs — where the reason for the failure is the last line, not the
  # first. A `docker build` failure reached the page as nine thousand
  # characters of apt-get output ending `"Building depe" <> ...`: the step
  # said it errored and the formatter had deleted why.
  defp describe(reason), do: inspect(reason, printable_limit: :infinity, limit: :infinity)

  # Every state change is announced. Doing it here rather than at each call
  # site means a transition cannot be added without being published — and a
  # step that moves without telling anyone is exactly the "watch it run"
  # failure, invisible until someone reloads.
  # What a run records must add to what the step already knew, never stand in
  # for it. `resources` is an `embeds_many` with `on_replace: :delete`, so
  # handing it one run's list deletes every resource an earlier run recorded —
  # and teardown works from that list, so what it forgets is exactly what leaks.
  #
  # Measured, not theorised: a step that recorded `hetzner/uat-box` and then
  # failed on a retry that had only made an ssh key came back holding
  # `["hetzner/key"]`. That is how a real recording left
  # `spex-story966-criterion8156-uat` running — run one created and recorded the
  # box, run two errored on a cassette miss, and the box became invisible.
  #
  # Earlier entries win on collision. A stale one costs nothing, because
  # teardown reads `{:error, :not_found}` as success; overwriting one could
  # turn an `adopted` resource into a `created` one and license teardown to
  # delete something Sam had before setup ran. Forgetting and over-claiming are
  # both worse than a duplicate.
  #
  # `verify/3`'s satisfied path deliberately still replaces: that list is read
  # back from the provider, so it is the one answer entitled to overrule what
  # was recorded before.
  # Not everything a step records is a thing it made. These describe what the
  # latest run *did* — which phases it reached, which version ended up live,
  # how it failed — and a later run's answer supersedes an earlier one rather
  # than joining it.
  #
  # Keeping them broke criterion 8008: a deploy whose migration fails must
  # never swap traffic, and the page showed a swap timestamp belonging to the
  # successful deploy before it. Nothing had swapped; the record had simply
  # stopped being about this run. Merging is right for a server, which outlives
  # the run that made it, and wrong for a phase, which does not.
  @run_scoped ~w(deploy_phase live_version deploy_failure)

  defp keeping_earlier(scope, key, partial) do
    earlier =
      case StepRepository.get(scope, key) do
        %{resources: resources} when is_list(resources) -> resources
        _ -> []
      end
      |> Enum.reject(&(&1.kind in @run_scoped))

    seen = MapSet.new(earlier, &{&1.kind, &1.location})

    earlier
    |> Enum.map(&Map.from_struct/1)
    |> Enum.concat(Enum.reject(partial, &MapSet.member?(seen, {&1[:kind], &1[:location]})))
  end

  # Verify's list is the provider's answer about what exists, and it overrules —
  # that is why the satisfied path replaces rather than merges. Ownership is the
  # one exception, because `origin` answers a different question than teardown
  # asks of it.
  #
  # `ensure_*` marks a resource `adopted` when it finds one already there, which
  # is right for "did I make this on *this* run" and wrong for "did this exist
  # before setup ever ran". So a DNS record setup created on the first walk came
  # back `adopted` on the second, and `Teardown.resource/3` spares adopted
  # resources — it released the server and left the record pointing at the
  # released address. Hetzner recycles those, so the name went on resolving to a
  # machine somebody else would be given: the subdomain takeover
  # `Teardown.environment/3` is written to prevent, arriving through the origin
  # field rather than through the ordering it guards.
  #
  # Once setup created a thing, it owns it. Adoption cannot take that back.
  #
  # The same rule `keeping_earlier/3` already applies on the run path — earlier
  # ownership wins — extended to the satisfied path, which had no merge at all.
  # It does not license the opposite: a *later* claim of `created` over an
  # earlier `adopted` stays refused, because that is a step restating something
  # Sam had before setup ran, and believing it would license destroying it.
  defp still_ours(scope, key, resources) do
    ours =
      case StepRepository.get(scope, key) do
        %{resources: earlier} when is_list(earlier) ->
          for r <- earlier, r.origin == "created", into: MapSet.new(), do: {r.kind, r.location}

        _ ->
          MapSet.new()
      end

    Enum.map(resources, fn resource ->
      if MapSet.member?(ours, {field(resource, :kind), field(resource, :location)}),
        do: Map.put(resource, :origin, "created"),
        else: resource
    end)
  end

  # `verify/3` returns plain maps from most steps and `%Resource{}` structs from
  # the ones that read a previous run's record back — `verify(:inbound, …)` hands
  # over the persisted `inbound_proof` that way. Structs do not implement Access,
  # so `resource[:kind]` raised `Resource.fetch/2 is undefined` on the one step
  # whose satisfied path returns them, which is a crash rather than a wrong
  # answer and took the whole walk down with it.
  defp field(resource, key), do: Map.get(resource, key)

  defp mark(scope, key, state, attrs) do
    row =
      StepRepository.upsert(
        scope,
        key,
        Map.merge(attrs, %{state: state, position: Sequence.position(key)})
      )

    announce(scope, {:provisioning, :step, row})
    row
  end
end
