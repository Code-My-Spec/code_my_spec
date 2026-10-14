defmodule CodeMySpec.ProvisioningPlan do
  @moduledoc """
  What setup a project needs and where each step stands, without running any
  of it.

  The step catalogue (`Sequence`), the persisted rows (`Step`,
  `StepRepository`) and the plan read from them. `Provisioning` runs the
  steps; this only reads, so the requirement graph's `deploy` gate can ask
  what is missing without depending on the engine that provisions it.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Configurations,
      CodeMySpec.Projects,
      CodeMySpec.Provisioning.EnvironmentRepository,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.Environment
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.ProvisioningPlan.{Sequence, StepRepository}
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

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

  A project that has never chosen gets everything; a user who wants less
  turns it off.

  `nil` ("never chosen", the full set) and `[]` ("chose none", nothing) are
  deliberately different, or turning everything off would read as never
  having chosen and the page would turn it all back on.
  """
  @spec setup_options(Project.t() | Scope.t()) :: [atom()]
  def setup_options(%Scope{active_project: project}), do: setup_options(project)
  def setup_options(%Project{setup_options: nil}), do: available_options()

  def setup_options(%Project{setup_options: stored}) do
    available = available_options()
    by_name = Map.new(available, &{to_string(&1), &1})

    # Looked up rather than `String.to_existing_atom/1`: an option whose step
    # was later removed is ignored, not raised on.
    stored |> Enum.flat_map(&List.wrap(Map.get(by_name, &1))) |> Enum.uniq()
  end

  def setup_options(_), do: available_options()

  ## Environments

  # Filtered here rather than in the seed: both rows exist, so promoting to
  # prod is one setting change.
  @doc """
  The environment rows this project's devops level actually permits — every
  row it has, unless `devops: :uat` has filtered production out. Seeds rows on
  first read, as the run does.
  """
  @spec permitted_environment_rows(Scope.t()) :: [Environment.t()]
  def permitted_environment_rows(scope),
    do: scope |> EnvironmentRepository.list() |> permitted(scope)

  @doc "Names of `permitted_environment_rows/1`."
  @spec permitted_environments(Scope.t()) :: [String.t()]
  def permitted_environments(scope),
    do: scope |> permitted_environment_rows() |> Enum.map(& &1.name)

  @doc """
  `permitted_environments/1` from the rows already there, seeding none — for a
  reader that must not write, the requirement graph's `deploy` gate.
  """
  @spec permitted_existing_environments(Scope.t()) :: [String.t()]
  def permitted_existing_environments(scope) do
    scope
    |> EnvironmentRepository.list_existing()
    |> permitted(scope)
    |> Enum.map(& &1.name)
  end

  defp permitted(rows, scope) do
    case devops_level(scope) do
      :uat -> Enum.reject(rows, &(&1.name == "prod"))
      _ -> rows
    end
  end

  @doc """
  The active project's devops level. No row, or a row predating the column,
  means nobody has said this project ships — the same answer the schema
  default gives.
  """
  @spec devops_level(Scope.t()) :: atom()
  def devops_level(scope),
    do: scope |> Configurations.get() |> ProjectConfiguration.devops_level()

  @doc """
  `project`'s devops level, read for any caller scope. Read, never
  `get_or_create/1`: loading a page must not write a configuration row for
  every project in the account.
  """
  @spec devops(Scope.t(), Project.t()) :: atom()
  def devops(%Scope{} = scope, %Project{} = project) do
    Utils.rescued("ProvisioningPlan.devops", :off, fn ->
      scope |> plan_scope(project) |> devops_level()
    end)
  end

  @doc """
  Production when there is one, because that is the site everything else
  (a reader, a webhook, a health check) actually reaches. Otherwise the
  first environment the project has, so a UAT-only project still gets one
  rather than none. `:content` cannot yet act on more than one environment
  (it proves itself against the project's single `client_api_url`/
  `content_bucket`), so its one row is attributed here.
  """
  @spec primary_environment(Scope.t()) :: String.t() | nil
  def primary_environment(scope), do: scope |> permitted_environments() |> primary_of()

  defp primary_of([]), do: nil
  defp primary_of(names), do: if("prod" in names, do: "prod", else: List.first(names))

  ## Plan

  @doc """
  The whole plan for a project, in order, before anything runs.

  Every step carries its current state. Steps the options exclude are
  absent, not present-and-skipped.

  A project-wide step is one entry. A per-environment step
  (`Sequence.scope/1 == :environment`) is one entry per environment, except
  `:content`, pinned to `primary_environment/1`.

  `seed: false` reads only the environment rows already there. A reader that
  must not write — the requirement graph — passes it; a project with no rows
  then plans its project-wide steps alone.
  """
  @spec plan(Scope.t(), [atom()], keyword()) :: [map()]
  def plan(%Scope{} = scope, enabled_options, opts \\ []) do
    persisted =
      scope |> StepRepository.list() |> Map.new(&{{&1.key, &1.environment}, &1})

    names =
      if Keyword.get(opts, :seed, true),
        do: permitted_environments(scope),
        else: permitted_existing_environments(scope)

    for step <- Sequence.for_options(enabled_options),
        environment <- step_environments(names, step),
        do: entry(step, environment, Map.get(persisted, {step.key, environment}))
  end

  @doc """
  The environments one sequence step plans over, out of `names`: `[nil]` for a
  project-wide step, the primary alone for `:content`, every name otherwise.
  """
  @spec step_environments([String.t()], map()) :: [String.t() | nil]
  def step_environments(_names, %{scope: :project}), do: [nil]
  def step_environments(names, %{key: :content}), do: [primary_of(names)]
  def step_environments(names, %{scope: :environment}), do: names

  # Two heads: "has this step ever run" asked once rather than per field.
  defp entry(step, environment, nil) do
    %{
      key: step.key,
      scope: step.scope,
      environment: environment,
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

  defp entry(step, environment, row) do
    %{
      key: step.key,
      scope: step.scope,
      environment: environment,
      label: step.label,
      why: step.why,
      position: Sequence.position(step.key),
      state: row.state || :not_started,
      attempted: row.attempted,
      provider_error: row.provider_error,
      paused_instructions: row.paused_instructions,
      # When the step last changed state; for a `done` row, when it finished.
      completed_at: row.updated_at,
      started_at: row.started_at,
      verified_at: row.verified_at,
      resources: row.resources || []
    }
  end

  ## Checklist

  # A step counts as present when it is `:done` or holds any resources: a
  # run can stop (`:running`/`:errored`/`:paused`) after creating something
  # real, and a `:done` step can have no resources.
  @doc """
  What `project` should have, from the same sequence the run uses, each entry
  `:present` or `:missing`. `plan/3` fills the gaps a run never reached.
  """
  @spec checklist(Scope.t(), Project.t(), keyword()) :: [map()]
  def checklist(%Scope{} = scope, %Project{} = project, plan_opts \\ []) do
    for step <- plan(plan_scope(scope, project), setup_options(project), plan_opts) do
      %{
        project_id: project.id,
        project_name: project.name,
        key: step.key,
        environment: step.environment,
        state: if(step.state == :done or step.resources != [], do: :present, else: :missing),
        detail: step.provider_error,
        # The last run's verdict and when it was recorded, beside the presence
        # verdict.
        step_state: step.state,
        recorded_at: if(step.state == :running, do: step.started_at, else: step.completed_at),
        paused_instructions: step.paused_instructions
      }
    end
  end

  @doc """
  The setup steps `environment` still misses: the checklist, narrowed to that
  environment's rows and the project-wide ones every environment stands on.
  The deploy requirement gates on this, so it and `devops_status` read one
  answer.

  Read without seeding environment rows, because the requirement graph calls
  it on every load and a read must not write. An environment with no row has
  not started setup at all: `{:error, :not_started}`.
  """
  @spec setup_missing(Scope.t(), Project.t(), String.t()) ::
          {:ok, [map()]} | {:error, :devops_off | :not_started}
  def setup_missing(%Scope{} = scope, %Project{} = project, environment) do
    case devops(scope, project) do
      :off ->
        {:error, :devops_off}

      _ ->
        checklist = checklist(scope, project, seed: false)

        if Enum.any?(checklist, &(&1.environment == environment)),
          do:
            {:ok,
             Enum.filter(
               checklist,
               &(&1.state == :missing and &1.environment in [nil, environment])
             )},
          else: {:error, :not_started}
    end
  end

  # The plan reads by project alone: step rows, environment rows and the
  # configuration are all keyed on it.
  defp plan_scope(scope, %Project{id: project_id} = project),
    do: %{scope | active_project: project, active_project_id: project_id}
end
