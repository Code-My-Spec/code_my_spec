defmodule CodeMySpec.Requirements.RequirementCalculator do
  @moduledoc """
  Computes requirement satisfaction from File records, Problems, and entity fields.

  Dispatches on `definition.check_type` instead of pattern-matching on requirement
  names. Handles component, story, and project requirements with a unified set of
  check types:

  - `:file_exists`   — File record with configured role exists
  - `:file_valid`    — File record with configured role has valid: true
  - `:path_exists`   — File at configured path exists in project file list
  - `:field_present` — Field on entity struct is not nil
  - `:field_true`    — Boolean field on entity struct is exactly `true`
  - `:no_problems`   — Zero Problem records from configured source
  - `:tests_passing` — Zero exunit Problems
  """

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Files.File
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Users.Scope

  @type computed_requirement :: %{
          name: String.t(),
          satisfied: boolean(),
          details: map()
        }

  # -- Public API --

  @doc """
  Compute satisfaction for all requirements of a component.
  """
  @spec compute_component(Scope.t(), Component.t(), Preloader.context() | nil) :: [
          computed_requirement()
        ]
  def compute_component(%Scope{} = scope, %Component{} = component, ctx \\ nil) do
    definitions = RequirementsRegistry.get_requirements_for_type(component.type)
    files = get_files(scope, component.id, ctx)

    Enum.map(definitions, fn definition ->
      compute_one(scope, component, definition, files, ctx)
    end)
  end

  @doc """
  Compute satisfaction for a single requirement definition against an entity.
  """
  def compute_one(scope, entity, definition, files, ctx \\ nil) do
    {satisfied, details} = check(definition, scope, entity, files, ctx)
    %{name: definition.name, satisfied: satisfied, details: details}
  end

  # -- Check dispatch by check_type --

  defp check(%{check_type: :file_exists, config: config}, scope, entity, files, _ctx) do
    role = config_role(config)
    has_role?(files, role, expected_path(scope, entity, role))
  end

  defp check(%{check_type: :file_valid, config: config}, _scope, _entity, files, _ctx) do
    role = config_role(config)
    has_valid_role?(files, role)
  end

  defp check(%{check_type: :path_exists, config: config}, scope, _entity, _files, ctx) do
    cond do
      path = config["path"] || config[:path] ->
        check_path_exists(scope, ctx, path)

      prefix = config["path_prefix"] || config[:path_prefix] ->
        check_path_prefix(scope, ctx, prefix)

      true ->
        {false, %{reason: "path_exists check missing path or path_prefix config"}}
    end
  end

  defp check(%{check_type: :field_present, config: config}, _scope, entity, _files, _ctx) do
    field = config_field(config)
    value = Map.get(entity, field)

    if is_nil(value) do
      {false, %{reason: "#{field} is not set"}}
    else
      {true, %{status: "#{field} is set"} |> Map.put(field, value)}
    end
  end

  # Distinct from :field_present because `false` is a legitimate value that
  # must read as unsatisfied — :field_present only rejects nil, so a latch
  # sitting at `false` would report satisfied.
  defp check(%{check_type: :field_true, config: config}, _scope, entity, _files, _ctx) do
    field = config_field(config)

    if Map.get(entity, field) == true do
      {true, %{status: "#{field} is set"}}
    else
      {false, %{reason: "#{field} is not set"}}
    end
  end

  defp check(%{check_type: :no_problems, config: config}, scope, entity, _files, ctx) do
    source = config_source(config)

    if analysis_fresh?(scope, source, ctx) do
      count = get_problem_count(scope, entity_id(entity), source, ctx)

      if count == 0 do
        {true, %{status: "No #{source} problems"}}
      else
        {false, %{reason: "#{count} #{source} problem(s)", count: count}}
      end
    else
      # Same rule `tests_passing` already applies, and it belongs here for a
      # second reason. There, stale results risk a false *pass*: zero recorded
      # failures against yesterday's code. Here the danger runs the other way —
      # a stale non-zero count is a false *fail*, and it is worse than it
      # sounds.
      #
      # An agent fixed four credo findings and was handed the same four back, at
      # the same line numbers, against code it had already corrected. For
      # "nesting too deep" or "alias order" there is no idempotent second fix:
      # to satisfy the list it would have to invent a *different* refactor of
      # correct code, degrading it — and those edits produce another snapshot
      # the next check reads while stale. That is a loop with no exit, and each
      # turn makes the code worse.
      #
      # The one this drill hit stopped only because the analyzers eventually
      # caught up. It reported the friction and refused to re-fix, which is the
      # right call and not one to depend on.
      {false, %{reason: "#{source} results not current — analysis pending or stale"}}
    end
  end

  defp check(%{check_type: :tests_passing}, scope, entity, files, ctx) do
    # Must have a test file before declaring tests passing
    has_test_file = Enum.any?(files, &(&1.role == :test))

    cond do
      not has_test_file ->
        {false, %{reason: "No test file exists yet"}}

      # Zero persisted failures only counts once the results are current —
      # a test run recorded against yesterday's code proves nothing about
      # the file the agent just wrote. Analysis runs in the background;
      # this flips true when its run lands.
      not analysis_fresh?(scope, "exunit", ctx) ->
        {false, %{reason: "Test results not current — analysis pending or stale"}}

      true ->
        count = get_problem_count(scope, entity_id(entity), "exunit", ctx)

        if count == 0 do
          {true, %{status: "No test failures"}}
        else
          {false, %{reason: "#{count} test failure(s)", count: count}}
        end
    end
  end

  defp check(%{check_type: :delegate, config: config}, scope, entity, _files, ctx) do
    module = config[:module] || config["module"]
    function = config[:function] || config["function"] || :check

    if is_nil(module) do
      {false, %{reason: "delegate check missing :module in config"}}
    else
      run_delegate(module, function, scope, entity, ctx)
    end
  end

  # Fallback for definitions without check_type (legacy or unknown)
  defp check(%{check_type: nil, name: name}, _scope, _entity, _files, _ctx) do
    {false, %{reason: "No check_type defined for requirement: #{name}"}}
  end

  defp check(%{check_type: check_type}, _scope, _entity, _files, _ctx) do
    {false, %{reason: "Unknown check_type: #{check_type}"}}
  end

  # Checkers that export an arity-3 clause are handed the preloaded context;
  # the rest keep the two-argument contract and query for themselves.
  #
  # Opt-in per checker rather than a flag day: `compute_story_nodes/3` calls
  # this once per story per definition, so a checker that queries four tables
  # does it 4×N times in one graph computation. Converting them one at a time
  # needs both shapes to work, and a checker that has not been converted is
  # exactly as correct as before.
  defp run_delegate(module, function, scope, entity, ctx) do
    module
    |> apply(function, delegate_args(module, function, scope, entity, ctx))
    |> normalize_delegate_result()
  rescue
    e -> {false, %{reason: "delegate check failed: #{Exception.message(e)}"}}
  end

  defp delegate_args(module, function, scope, entity, ctx) do
    if is_map(ctx) and Code.ensure_loaded?(module) and function_exported?(module, function, 3),
      do: [scope, entity, ctx],
      else: [scope, entity]
  end

  defp normalize_delegate_result({true, details}), do: {true, details}
  defp normalize_delegate_result({false, details}), do: {false, details}
  defp normalize_delegate_result({:ok, :valid}), do: {true, %{status: "delegate check passed"}}
  defp normalize_delegate_result({:ok, :valid, advisory}), do: {true, %{advisory: advisory}}
  defp normalize_delegate_result({:ok, :invalid, reason}), do: {false, %{reason: reason}}

  defp normalize_delegate_result(_),
    do: {false, %{reason: "delegate check returned unexpected result"}}

  # -- Config helpers --

  defp config_role(config) do
    config[:role] || config["role"] || raise "file check missing :role in config"
  end

  defp config_source(config) do
    config[:source] || config["source"] || raise "no_problems check missing :source in config"
  end

  defp config_field(config) do
    config[:field] || config["field"] || raise "field_present check missing :field in config"
  end

  # -- Entity helpers --

  defp entity_id(%Component{id: id}), do: id
  defp entity_id(%{id: id}), do: id

  defp expected_path(%Scope{active_project: project}, %Component{} = component, role) do
    file_key = role_to_file_key(role)

    CodeMySpec.Utils.component_files(component, project)
    |> Map.get(file_key)
  end

  defp expected_path(_scope, _entity, _role), do: nil

  defp role_to_file_key(:spec), do: :spec_file
  defp role_to_file_key(:implementation), do: :code_file
  defp role_to_file_key(:test), do: :test_file
  defp role_to_file_key(:review), do: :review_file
  defp role_to_file_key(_), do: nil

  # -- Path checks (project-level) --

  # Rows only. These used to fall back to statting the disk, on the stated
  # grounds that "many project-level paths aren't classified by FileSync, so
  # the DB won't have them — filesystem is authoritative". That is no longer
  # true: every path these six requirements gate on now classifies to a role
  # (`ClassifiableArtifactsTest` holds the list), so the row is there whenever
  # the file is.
  #
  # The fallback was also the thing that made two harnesses disagree about one
  # project. It only ever fires when the file is on disk and not yet a row, and
  # in that window the heavy harness — which has a working copy — answers
  # satisfied while the server, whose `scope.environment` is nil, answers
  # unsatisfied. Same project, same instant, two answers, and the one an agent
  # gets depends on which process it asked.
  #
  # Reading rows costs a scan of lag on a freshly written file and gives one
  # answer to everyone. That is the trade this whole projection is built on:
  # everything else here already reads rows, and a file the scanner has not
  # seen is a file the graph does not know about.
  defp check_path_exists(scope, ctx, path) do
    if path_tracked?(scope, ctx, path) do
      {true, %{path: path}}
    else
      {false, %{reason: "File missing: #{path}"}}
    end
  end

  defp check_path_prefix(scope, ctx, prefix) do
    case prefix_count(scope, ctx, prefix) do
      0 -> {false, %{reason: "No files at #{prefix}"}}
      n -> {true, %{status: "#{n} file(s) at #{prefix}"}}
    end
  end

  # Preloaded when there is a context, queried when there is not — the same
  # two-clause shape `get_files/3` and `get_problem_count/4` already use, and
  # the reason this conversion is not just "delete the fallback".
  #
  # `Evaluator` calls `compute_one/4` without a context, so on the stop-hook
  # path — the one that runs on every agent turn — `ctx` is nil and there are
  # no preloaded files to consult. Dropping to `{false, "File missing"}` there
  # blocks the stop on a file the agent had just written and synced.
  defp path_tracked?(_scope, ctx, path) when is_map(ctx) do
    ctx[:files_by_path] && Map.has_key?(ctx.files_by_path, path)
  end

  defp path_tracked?(%Scope{active_project_id: project_id} = scope, _ctx, path) do
    File
    |> where([f], f.project_id == ^project_id and f.path == ^path)
    |> scope_to_harness(scope)
    |> Repo.exists?()
  end

  defp prefix_count(_scope, ctx, prefix) when is_map(ctx) do
    case ctx[:files_by_project] do
      files when is_list(files) -> Enum.count(files, &String.starts_with?(&1.path, prefix))
      _ -> 0
    end
  end

  # Matched in Elixir rather than with a `LIKE`: the prefix is a config value
  # and `_` is a single-character wildcard in both Postgres and SQLite, so a
  # future prefix containing one would quietly over-match. One indexed column
  # for one project is a cheap enough read to not need the wildcard.
  defp prefix_count(%Scope{active_project_id: project_id} = scope, _ctx, prefix) do
    File
    |> where([f], f.project_id == ^project_id)
    |> scope_to_harness(scope)
    |> select([f], f.path)
    |> Repo.all()
    |> Enum.count(&String.starts_with?(&1, prefix))
  end

  # The same rule `Preloader.load/1` applies, for the same reason and with the
  # same asymmetry.
  #
  # These two fallbacks run when there is no preloaded context — which is the
  # stop-hook path, because `Evaluator` calls `compute_one/4` without one. So
  # every `path_exists` requirement on every agent turn was asking "does any
  # checkout have this file", and answering yes.
  #
  # The six that use it are all `.code_my_spec/` project paths — a technical
  # strategy, a QA plan, a journey — which is exactly the category that differs
  # between working copies, because one checkout writing it is the work the
  # requirement is asking for. A second checkout that already had it made the
  # first one's requirement read as done.
  #
  # Over-satisfaction is the dangerous direction: an unsatisfied requirement
  # reported satisfied is work skipped and never noticed, where the reverse is
  # work done twice and immediately obvious.
  #
  # Loose on a nil harness, matching the preloader: a scope with no working copy
  # is the UI asking, and refusing there took the graph out of the web view and
  # failed 86 spex. An agent's scope always carries a harness because the plug
  # that builds it does.
  defp scope_to_harness(query, %Scope{active_harness_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_harness_id: harness_id}),
    do: where(query, [f], f.harness_id == ^harness_id)

  # -- File checks --

  defp has_role?(files, role, expected_path) do
    if Enum.any?(files, &(&1.role == role)) do
      {true, %{status: "#{role} file exists"}}
    else
      details = %{reason: "#{role} file missing"}

      details =
        if expected_path, do: Map.put(details, :expected_path, expected_path), else: details

      {false, details}
    end
  end

  defp has_valid_role?(files, role) do
    case Enum.find(files, &(&1.role == role)) do
      nil ->
        {false, %{reason: "#{role} file missing"}}

      %{valid: true} ->
        {true, %{status: "#{role} file valid"}}

      %{valid: false, validation_errors: errors} ->
        {false, %{reason: "#{role} file invalid", errors: errors}}

      %{valid: nil} ->
        {false, %{reason: "#{role} file not yet validated"}}
    end
  end

  # -- Data access (preloaded or query) --

  defp get_files(_scope, component_id, %{files_by_component: fbc}) do
    Map.get(fbc, component_id, [])
  end

  defp get_files(%Scope{active_project_id: project_id}, component_id, nil) do
    File
    |> where([f], f.project_id == ^project_id and f.component_id == ^component_id)
    |> Repo.all()
  end

  defp get_problem_count(_scope, component_id, source, %{problems_by_component: pbc}) do
    pbc
    |> Map.get(component_id, %{})
    |> Map.get(source, 0)
  end

  defp get_problem_count(%Scope{active_project_id: project_id}, component_id, source, nil) do
    Problem
    |> where(
      [p],
      p.project_id == ^project_id and p.component_id == ^component_id and p.source == ^source
    )
    |> Repo.aggregate(:count)
  end

  # Freshness of a source's latest analysis run vs the current inputs.
  # Preloaded per project; falls back to a direct ledger check for legacy
  # callers without a ctx.
  defp analysis_fresh?(_scope, source, %{analysis_fresh: fresh}) when is_map(fresh) do
    Map.get(fresh, source, false)
  end

  defp analysis_fresh?(scope, source, _ctx), do: CodeMySpec.Analysis.fresh?(scope, source)
end
