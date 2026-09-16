defmodule CodeMySpec.Requirements.RequirementCalculator do
  @moduledoc """
  Computes requirement satisfaction from File records, Problems, and entity fields.

  Dispatches on `definition.check_type` instead of pattern-matching on requirement
  names. Handles component, story, and project requirements with a unified set of
  check types:

  - `:file_exists`   — File record with configured role exists
  - `:file_valid`    — File record with configured role has valid: true
  - `:path_exists`   — File at configured path exists in project file list
  - `:component_exists` — Story's `component_id` resolves to a component that exists
  - `:field_present` — Field on entity struct is not nil
  - `:field_true`    — Boolean field on entity struct is exactly `true`
  - `:no_problems`   — Zero Problem records from configured source
  - `:tests_passing` — Zero exunit Problems
  - `:bdd_specs_covered` — File of configured role exists for every acceptance
    criterion on the story, not merely for the story as a whole
  """

  import Ecto.Query

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Deploys
  alias CodeMySpec.Files.File
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

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

  # Per-criterion, not per-story: a story with any one file of `role` used to
  # read satisfied regardless of how many criteria it had. A criterion added
  # or reworded after the first spex pass then has no spec and nothing asks
  # for one, because the other criteria's files keep the story looking done
  # (issue 644279a9).
  defp check(%{check_type: :bdd_specs_covered, config: config}, scope, entity, files, _ctx) do
    role = config_role(config)
    check_bdd_specs_covered(scope, entity, files, role)
  end

  defp check(%{check_type: :path_exists, config: config}, scope, _entity, _files, ctx) do
    cond do
      path = MapAccess.get(config, :path) ->
        check_path_exists(scope, ctx, path)

      prefix = MapAccess.get(config, :path_prefix) ->
        check_path_prefix(scope, ctx, prefix)

      true ->
        {false, %{reason: "path_exists check missing path or path_prefix config"}}
    end
  end

  # The story's component is linked when it resolves to a component that exists,
  # not when the field is merely set.
  #
  # A component's id is a pure function of its project and module name, so the
  # migration computes it rather than looking it up — which lets a story name the
  # component it belongs to before the working copy has synced it. The id is
  # right; the row is not there yet, and `:field_present` would call that linked.
  #
  # The two reasons are different work: nothing to point at is an architecture
  # question, and pointing at something absent resolves itself when the sync
  # runs. Saying which is the difference between "map this story" and "wait".
  defp check(%{check_type: :component_exists}, scope, entity, _files, _ctx) do
    case Map.get(entity, :component_id) do
      nil ->
        {false, %{reason: "component_id is not set"}}

      component_id ->
        component_exists_details(scope, component_id)
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
  #
  # The reason names what sets the latch, because a latch is the one check type
  # where doing the work is not enough and nothing else says so. `specs_ready`
  # is set only by `FixBddSpecs.evaluate/2` reaching its empty-problems branch;
  # a completed spex sweep does not touch it. So three full sweeps went green —
  # 213s, one killed at twelve minutes, 393s — and each re-check of the
  # requirement still said "specs_ready is not set", which reads as a broken
  # gate rather than a pending step. Three wrong theories came out of that, one
  # of them filed as an issue that had to be withdrawn. `evaluate_task` was
  # called once afterwards and it flipped immediately, on evidence that had
  # been in the database the whole time.
  defp check(%{check_type: :field_true, config: config} = definition, _scope, entity, _, _ctx) do
    field = config_field(config)

    if Map.get(entity, field) == true do
      {true, %{status: "#{field} is set"}}
    else
      {false, %{reason: "#{field} is not set — #{latch_hint(definition)}"}}
    end
  end

  defp check(%{check_type: :no_problems, config: config}, scope, entity, _files, ctx) do
    source = config_source(config)
    problem_verdict(scope, entity, source, ctx, "#{source} problem")
  end

  defp check(%{check_type: :tests_passing}, scope, entity, files, ctx) do
    if Enum.any?(files, &(&1.role == :test)) do
      problem_verdict(scope, entity, "exunit", ctx, "test failure")
    else
      {false, %{reason: "No test file exists yet"}}
    end
  end

  defp check(%{check_type: :delegate, config: config}, scope, entity, _files, ctx) do
    module = MapAccess.get(config, :module)
    function = MapAccess.get(config, :function, :check)

    if is_nil(module) do
      {false, %{reason: "delegate check missing :module in config"}}
    else
      run_delegate(module, function, scope, entity, ctx)
    end
  end

  # Is this story live on the environment the definition names?
  #
  # The environment comes from config rather than being baked into a function
  # name, because environments are rows: a project has whatever set it has, and
  # `uat_check/2` could only ever answer for one of them.
  #
  # `Predicates.satisfied(:deployed, …)` is the query form of this and must
  # agree with it — same table, same `health_verified_at` rule.
  defp check(%{check_type: :deployed, config: config}, scope, entity, _files, _ctx) do
    deployed_verdict(scope, entity, environment_from(config))
  end

  # Is every released story live on that environment?
  #
  # Project-scoped, and the release gate the prod half of story 841 needs:
  # production goes out when the graph is green, not when one story is.
  defp check(%{check_type: :all_deployed, config: config}, scope, _entity, _files, _ctx) do
    environment = environment_from(config)

    if Deploys.environment_deployed?(scope, environment) do
      {true, %{status: "every released story is live on #{environment}"}}
    else
      {false, %{status: "not every released story is live on #{environment}"}}
    end
  end

  # Fallback for definitions without check_type (legacy or unknown)
  defp check(%{check_type: nil, name: name}, _scope, _entity, _files, _ctx) do
    {false, %{reason: "No check_type defined for requirement: #{name}"}}
  end

  defp check(%{check_type: check_type}, _scope, _entity, _files, _ctx) do
    {false, %{reason: "Unknown check_type: #{check_type}"}}
  end

  defp component_exists_details(scope, component_id) do
    case Repo.get_by(Component, id: component_id, project_id: scope.active_project_id) do
      nil ->
        {false,
         %{
           reason:
             "component #{component_id} does not exist yet — it is named correctly and " <>
               "appears when the working copy syncs the module it projects from",
           component_id: component_id
         }}

      _component ->
        {true, %{status: "component_id is set", component_id: component_id}}
    end
  end

  # Stale analysis is asymmetric: serve the findings, refuse the clean.
  #
  # A stale count above zero is a real finding that was true of recent code, so
  # it is reported — withholding it left any source slower than the edit cadence
  # permanently "pending", never answering at all (issue 7a7eed33). A stale zero
  # is the dangerous direction: reporting clean from a run that never looked at
  # the current code is a false pass, and that one still refuses.
  #
  # The reason says which it is. An agent once re-fixed four credo findings it
  # had already corrected, because a stale list is indistinguishable from a
  # current one when nothing says so — and for "nesting too deep" there is no
  # idempotent second fix, so it degrades correct code on every pass.
  # The component's own problem count, and nothing else.
  #
  # Freshness used to be half of this verdict, and storing the product of a
  # per-component count and a project-wide boolean is what made an analyzer
  # finishing cost 1116 of 1347 requirements. The count is durable and belongs
  # in a row; whether the run behind it is still current is a qualifier applied
  # when the graph is served — `RequirementGraph.serve/2`. Criterion 3448.
  #
  # The asymmetry the old table encoded is unchanged, only relocated: a stale
  # count above zero is still reported (it was true of recent code), and a stale
  # zero is still refused (a clean result from a run that never saw the current
  # code is a false pass). The overlay only ever downgrades, so nothing here can
  # be turned into a pass by it.
  defp problem_verdict(scope, entity, source, ctx, noun) do
    case get_problem_count(scope, entity_id(entity), source, ctx) do
      0 -> {true, %{status: "No #{noun}s", analysis_source: source}}
      n -> {false, %{reason: "#{n} #{noun}(s)", count: n, analysis_source: source}}
    end
  end

  # Checkers that export an arity-3 clause are handed the preloaded context;
  # the rest keep the two-argument contract and query for themselves.
  #
  # Opt-in per checker rather than a flag day: `compute_story_nodes/3` calls
  # this once per story per definition, so a checker that queries four tables
  # does it 4×N times in one graph computation. Converting them one at a time
  # needs both shapes to work, and a checker that has not been converted is
  # exactly as correct as before.
  #
  # A raising checker is not caught. It used to become
  # `{false, "delegate check failed: …"}`, which reads as protection and is not:
  # every delegate module is ours — nine of them, all in this application — so a
  # raise is a bug in our code rather than a condition to degrade around, and
  # `false` is the verdict most nodes carry most of the time. A broken checker
  # was therefore indistinguishable from an unsatisfied requirement in every
  # view that counts nodes, and nothing logged. The reason string only surfaced
  # if someone opened that one node's details.
  #
  # A checker with a condition it genuinely cannot evaluate says so in the
  # result — `{false, %{reason: …}}` or `{:ok, :invalid, reason}` — which is the
  # difference between an answer and a crash, and is what the shape is for.
  defp run_delegate(module, function, scope, entity, ctx) do
    module
    |> apply(function, delegate_args(module, function, scope, entity, ctx))
    |> normalize_delegate_result()
  end

  defp delegate_args(module, function, scope, entity, ctx) do
    if is_map(ctx) and Code.ensure_loaded?(module) and function_exported?(module, function, 3),
      do: [scope, entity, ctx],
      else: [scope, entity]
  end

  @doc """
  A delegate's answer in the `{satisfied?, details}` shape the graph stores.

  Public because `Requirements.Handlers` settles some delegate-backed
  requirements from events and has to land on the same shape a recompute would.
  Reimplementing this mapping there would be a second copy of the contract, and
  the copy that drifts is the one that decides what an agent is asked to do.
  """
  @spec normalize_delegate_result(term()) :: {boolean(), map()}
  def normalize_delegate_result(result)

  def normalize_delegate_result({true, details}), do: {true, details}
  def normalize_delegate_result({false, details}), do: {false, details}
  def normalize_delegate_result({:ok, :valid}), do: {true, %{status: "delegate check passed"}}
  def normalize_delegate_result({:ok, :valid, advisory}), do: {true, %{advisory: advisory}}
  def normalize_delegate_result({:ok, :invalid, reason}), do: {false, %{reason: reason}}

  def normalize_delegate_result(_),
    do: {false, %{reason: "delegate check returned unexpected result"}}

  # -- Config helpers --

  defp config_role(config) do
    MapAccess.get(config, :role) || raise "file check missing :role in config"
  end

  defp config_source(config) do
    MapAccess.get(config, :source) || raise "no_problems check missing :source in config"
  end

  defp config_field(config) do
    MapAccess.get(config, :field) || raise "field_present check missing :field in config"
  end

  # Names the module, because "evaluate the task" is not actionable to a reader
  # who does not know which task owns the latch.
  defp latch_hint(%{satisfied_by: module}) when not is_nil(module) do
    "it is set by evaluating #{inspect(module)}, not by doing the work. " <>
      "If the work is done, call `evaluate_task` — re-running the analysis will " <>
      "not set it however many times it passes."
  end

  defp latch_hint(_definition), do: "nothing has recorded it yet."

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
  # Existence is necessary, not sufficient. Every path these six gate on is
  # classified, and classification runs the artifact's validator — so the row
  # already carries a verdict. Reading only `exists?` threw that verdict away
  # and let a QA plan missing every required section satisfy `qa_setup`, whose
  # own description is "QA plan exists with App Overview, Tools Registry, and
  # Seed Strategy". Two of the six say "and valid" outright.
  #
  # `valid: nil` means no validator applies to that role, which is a pass —
  # only an explicit `false` is a failure. The errors are carried into the
  # reason because the agent's next move depends on which section is missing,
  # and "File invalid" alone does not say.
  # A path can match more than one row: `scope_to_harness/2` does not filter
  # when the scope carries no harness, which is every read the web UI makes.
  # So this asks the list a question rather than demanding a single row —
  # `Repo.one` would raise there, and refusing on a harness mismatch is what
  # took the graph out of the web view once already.
  #
  # One valid copy is enough. Reporting invalid because some other working
  # copy has a stale row would block an agent on a file it cannot see.
  defp environment_from(config), do: MapAccess.get(config, :environment)

  defp deployed_verdict(_scope, _entity, nil),
    do: {false, %{reason: "deployed check missing :environment in config"}}

  defp deployed_verdict(scope, %{id: story_id}, environment) do
    if Deploys.deployed?(scope, story_id, environment) do
      {true, %{status: "deployed to #{environment} and health-verified"}}
    else
      {false,
       %{status: "not deployed to #{environment}, or deployed without a passing health check"}}
    end
  end

  defp deployed_verdict(_scope, _entity, _environment),
    do: {false, %{status: "no story to check"}}

  defp check_path_exists(scope, ctx, path) do
    case tracked_files(scope, ctx, path) do
      [] ->
        {false, %{reason: "File missing: #{path}"}}

      files ->
        case Enum.reject(files, &(&1.valid == false)) do
          [_ | _] ->
            {true, %{path: path}}

          [] ->
            {false, %{reason: "File invalid: #{path} — #{describe_validation_errors(hd(files))}"}}
        end
    end
  end

  @doc """
  How an invalid file explains itself in a `path_exists` verdict.

  `validation_errors` is keyed by concern, and the keys vary by role — the
  scanner writes `%{"reason" => _}` for specs and reviews, `%{error: _}` for
  read failures, and a key per missing section for setup files. Join the values
  rather than guessing at a shape.

  Public for `Requirements.Handlers`, which settles the six project
  `path_exists` requirements from a profile and has to produce the same
  sentence. It had its own rendering and the diff caught the drift: the keys
  were interpolated too, so `qa_journey_plan` explained itself as
  `data: %{}; errors: %{"plan" => …}` where a recompute wrote the messages
  alone.
  """
  @spec describe_validation_errors(map()) :: String.t()
  def describe_validation_errors(%{validation_errors: errors})
       when is_map(errors) and errors != %{} do
    errors
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join("; ", fn {_key, value} -> format_validation_error(value) end)
  end

  def describe_validation_errors(_file), do: "no detail recorded"

  # Values are usually the validator's message, but not always — some roles
  # write a nested map, and `to_string/1` raises on those rather than saying
  # anything useful.
  defp format_validation_error(value) when is_binary(value), do: value
  defp format_validation_error(value) when is_atom(value), do: to_string(value)
  defp format_validation_error(value), do: inspect(value)

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
  defp tracked_files(_scope, ctx, path) when is_map(ctx) do
    case ctx[:files_by_path] && Map.get(ctx.files_by_path, path) do
      nil -> []
      file -> [file]
    end
  end

  defp tracked_files(%Scope{active_project_id: project_id} = scope, _ctx, path) do
    File
    |> where([f], f.project_id == ^project_id and f.path == ^path)
    |> scope_to_harness(scope)
    |> Repo.all()
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
  defp scope_to_harness(query, %Scope{active_working_copy_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_working_copy_id: working_copy_id}),
    do: where(query, [f], f.working_copy_id == ^working_copy_id)

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

  defp check_bdd_specs_covered(scope, %{id: story_id}, files, role) do
    scope
    |> AcceptanceCriteria.list_story_criteria(story_id)
    |> bdd_specs_covered(files, role)
  end

  @doc """
  Whether every criterion on a story has a file of `role` behind it.

  The verdict on its own, separated from the query that feeds it, so
  `Requirements.Handlers` can settle this requirement across every story from
  one read instead of one query per story — and, more to the point, so it
  cannot answer a different question.

  It did exactly that. `bdd_specs_exist` was a row in the handler's file table
  meaning "this story has any file in this role", which was the rule until
  `f97e1216d` made it per criterion. The table did not follow, the handler went
  on passing stories with a spec file and uncovered criteria, and nothing said
  so until a diff against this module on a merged tree.

  `[]` is unsatisfied rather than a pass. `168335ecf` briefly made a story with
  no criteria fall back to any-file semantics and `89bf9bf0b` took it back out:
  a story nobody has run Three Amigos on has not covered its criteria, it has
  no criteria to cover.
  """
  @spec bdd_specs_covered([map()], [map()], atom()) :: {boolean(), map()}
  def bdd_specs_covered(criteria, files, role)

  def bdd_specs_covered([], _files, _role),
    do: {false, %{reason: "no acceptance criteria on this story"}}

  def bdd_specs_covered(criteria, files, role) do
    covered_paths =
      files
      |> Enum.filter(&(&1.role == role))
      |> MapSet.new(& &1.path)

    missing =
      criteria
      |> Enum.filter(fn c ->
        is_nil(c.spec_path) or c.spec_path == "" or
          not MapSet.member?(covered_paths, c.spec_path)
      end)
      |> Enum.map(& &1.id)

    if missing == [] do
      {true, %{status: "#{role} file exists for every criterion"}}
    else
      {false,
       %{
         reason: "#{length(missing)} of #{length(criteria)} criteria missing #{role} file",
         missing_criteria_ids: missing
       }}
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
end
