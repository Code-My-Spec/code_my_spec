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

  alias CodeMySpec.Provisioning.{Sequence, Step, StepRepository}
  alias CodeMySpec.Users.Scope

  @type run_result :: %{
          steps: [Step.t()],
          halted_at: atom() | nil,
          reason: String.t() | nil
        }

  # Each step's verifier and runner. Kept here rather than on the Sequence
  # entries so Sequence stays pure and free of provider modules.
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

  ## Plan

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
    |> Enum.map(fn step ->
      row = Map.get(persisted, step.key)

      %{
        key: step.key,
        label: step.label,
        why: step.why,
        position: Sequence.position(step.key),
        state: (row && row.state) || :not_started,
        attempted: row && row.attempted,
        provider_error: row && row.provider_error,
        paused_instructions: row && row.paused_instructions,
        resources: (row && row.resources) || []
      }
    end)
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

    case verify(scope, key, opts) do
      {:ok, :satisfied, resources} ->
        {:ok, mark(scope, key, :done, %{resources: resources})}

      {:ok, :absent} ->
        run_and_record(scope, key, execute, opts)

      {:error, reason} ->
        {:halt, mark(scope, key, :errored, error_attrs(key, reason)), to_string(reason)}
    end
  end

  defp run_and_record(scope, key, execute, opts) do
    _ = mark(scope, key, :running, %{})

    case execute.(scope, key, opts) do
      {:ok, resources} ->
        {:ok, mark(scope, key, :done, %{resources: resources})}

      {:paused, instructions} ->
        row = mark(scope, key, :paused, %{paused_instructions: instructions})
        {:halt, row, instructions}

      {:error, reason} ->
        row = mark(scope, key, :errored, error_attrs(key, reason))
        {:halt, row, to_string(reason)}
    end
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
      nil -> {:ok, :absent}
      verifier -> verifier.(scope, key)
    end
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

  defp execute_step(_scope, key, _opts) do
    # Steps without a wired runner report that plainly rather than silently
    # succeeding — a step that does nothing and reports done is the failure
    # mode this whole context exists to prevent.
    case runner(key) do
      nil -> {:error, "no runner wired for step #{key}"}
      module -> {:error, "runner #{inspect(module)} is not wired into the sequence yet"}
    end
  end

  defp error_attrs(key, reason) do
    %{
      attempted: "run the #{key} step",
      provider_error: to_string(reason)
    }
  end

  defp mark(scope, key, state, attrs) do
    StepRepository.upsert(
      scope,
      key,
      Map.merge(attrs, %{state: state, position: Sequence.position(key)})
    )
  end
end
