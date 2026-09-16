defmodule CodeMySpec.Requirements.Handlers do
  @moduledoc """
  Domain events applied to the projection, without re-deriving anything.

  ## The shape

  Three tables and a lookup function, which is the whole of it:

    * `@dirties` — which profiles an event kind invalidates.
    * `@fed_by` — which requirements each profile settles.
    * `settle/2` — one clause per requirement, reading its profile.

  An event dirties one or more profiles, each profile is loaded once
  (`Profiles.load/2`), and every requirement fed by those profiles is settled
  from it in memory. Adding a requirement is a `settle/2` clause and a name in
  `@fed_by`. Adding a source is a profile.

  What it is *not* is a query per handler. Five `file_exists` names all read the
  same thing — which roles a component has files for — and asking five times is
  how a handler-per-requirement design turns back into the pass it replaced.

  ## Why this beats re-deriving

  An invalidation says *an entity moved*, and the only way to answer one is to
  recompute that entity: every requirement it has, every checker. One incoming
  issue ran 22 checkers to settle the one it could have moved — 238ms.

  An issue at or above the threshold **is** `issues_triaged = false`. The whole
  issue surface is now three queries and settles in 7ms, whatever the project's
  size.

  ## Set-based, so population size stops mattering

  A requirement is settled across every entity at once: the default goes on with
  one write, then the handful the profile named are corrected. Thirty-eight
  stories or three thousand — same three queries, same two writes.

  ## No handler is a valid answer

  `:no_handler` means nothing here knows about this event, and the caller falls
  back to invalidating and recomputing — correct, and slow. That is what lets
  requirements move across one at a time while the shadow diff scores either
  path identically.

  `{:ok, [], []}` is a different answer: the event happened and moved nothing
  the graph reads. Collapsing the two would let an uninteresting event silently
  skip work it owed.
  """

  alias CodeMySpec.Deploys
  alias CodeMySpec.Requirements.Profiles
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Users.Scope

  @type change :: %{
          entity_type: String.t(),
          entity_id: term(),
          name: String.t(),
          satisfied: boolean(),
          details: map()
        }

  @typedoc """
  A requirement settled across every entity of a type at once.

  `default` is what it is for entities the profile did not name; `except` is the
  handful it did. The satisfied direction is usually the default — a story with
  no unresolved issue is resolved — which is what lets one query settle a
  population rather than only its exceptions.
  """
  @type sweep :: %{
          entity_type: String.t(),
          name: String.t(),
          default: boolean(),
          default_details: map(),
          except: [change()]
        }

  # Which profiles an event invalidates. The only place an event kind appears.
  @dirties %{
    "issue_created" => [:issues],
    "issue_accepted" => [:issues],
    "issue_dismissed" => [:issues],
    "issue_resolved" => [:issues],
    "issue_updated" => [:issues],
    # A run landing moves spex freshness, and writes problems.
    "analysis_completed" => [:specs, :problems],
    # A sync moves the files themselves, and with them spex freshness and every
    # story's own spec files.
    "files_synced" => [:files, :specs],
    "problems_changed" => [:problems],
    # A story's own row moves `specs_ready` and the component it names.
    "story_changed" => [:specs, :links],
    # A component appearing or going decides whether a story naming it has
    # something real to point at.
    "component_changed" => [:links],
    "deploy_changed" => [:links]
  }

  # What each requirement reads. Declared per requirement rather than per
  # profile, because `tests_passing` reads two — whether the component has a
  # test file at all, and how many exunit problems it has — and a table keyed
  # the other way cannot say that.
  @requirement_profiles %{
    "issues_triaged" => [:issues],
    "issues_resolved" => [:issues],
    "story_issues_resolved" => [:issues],
    "bdd_specs_passing" => [:specs],
    "spec_file" => [:files],
    "spec_valid" => [:files],
    "test_file" => [:files],
    "test_spec_alignment" => [:files],
    "review_file" => [:files],
    "review_valid" => [:files],
    "implementation_file" => [:files],
    "bdd_specs_exist" => [:files],
    "technical_strategy" => [:files],
    "code_generation" => [:files],
    "qa_setup" => [:files],
    "qa_journey_plan" => [:files],
    "qa_journey_execute" => [:files],
    "qa_journey_wallaby" => [:files],
    "tests_passing" => [:files, :problems],
    "component_linked" => [:links],
    "deploy" => [:links]
  }

  # Every `file_exists` and `file_valid` requirement, as a table. Each of the
  # eight maps to exactly one role and one kind across all fifteen graphs —
  # checked, not assumed — so these are two shapes parameterised rather than
  # eight handlers. 76 of the graph's 110 definitions.
  @file_requirements %{
    "spec_file" => {:exists, :spec, "component"},
    "spec_valid" => {:valid, :spec, "component"},
    "test_file" => {:exists, :test, "component"},
    "test_spec_alignment" => {:valid, :test, "component"},
    "review_file" => {:exists, :review, "component"},
    "review_valid" => {:valid, :review, "component"},
    "implementation_file" => {:exists, :implementation, "component"},
    "bdd_specs_exist" => {:exists, :bdd_spec, "story"}
  }

  # The six project `path_exists` requirements, by what they look for.
  @path_requirements %{
    "technical_strategy" => {:path, ".code_my_spec/architecture/decisions.md"},
    "code_generation" => {:path, ".code_my_spec/tasks/code_generation.sh"},
    "qa_setup" => {:path, ".code_my_spec/qa/plan.md"},
    "qa_journey_plan" => {:path, ".code_my_spec/qa/journey_plan.md"},
    "qa_journey_execute" => {:path, ".code_my_spec/qa/journey_result.md"},
    "qa_journey_wallaby" => {:prefix, "test/journeys/"}
  }

  # Which file key `Utils.component_files/2` holds the expected path under.
  # `has_role?/3`'s own mapping, and `nil` for a role with no canonical place —
  # a `:bdd_spec` path is assigned per criterion, not derived from the module.
  @expected_file_key %{
    spec: :spec_file,
    implementation: :code_file,
    test: :test_file,
    review: :review_file
  }

  @doc """
  What this event does to the projection.

  `{:ok, changes, sweeps}` — individual rows to set, and requirements to settle
  across a whole population.
  """
  @spec apply_event(Scope.t(), String.t(), map()) ::
          {:ok, [change()], [sweep()]} | :no_handler
  def apply_event(%Scope{} = scope, kind, _payload) do
    case Map.get(@dirties, kind) do
      nil ->
        :no_handler

      dirty ->
        names = requirements_reading(dirty)
        profiles = load_profiles(scope, names)

        {:ok, [], Enum.map(names, &settle(&1, profiles))}
    end
  end

  # Every requirement that reads at least one of the dirtied profiles. A
  # requirement reading two is settled once, not once per profile.
  defp requirements_reading(dirty) do
    for {name, profiles} <- @requirement_profiles,
        Enum.any?(profiles, &(&1 in dirty)),
        do: name
  end

  # The union of what those requirements need, each loaded once however many
  # read it. This is the whole reason profiles are separate from handlers.
  defp load_profiles(scope, names) do
    names
    |> Enum.flat_map(&Map.fetch!(@requirement_profiles, &1))
    |> Enum.uniq()
    |> Map.new(&{&1, Profiles.load(scope, &1)})
  end

  # -- One clause per requirement. Each reads its profile and nothing else. --

  defp settle("issues_triaged", %{issues: profile}),
    do:
      project_sweep(
        "issues_triaged",
        profile.incoming == [],
        %{status: "No untriaged issues at #{profile.threshold}+ severity"},
        %{reason: "#{length(profile.incoming)} untriaged #{profile.threshold}+ issues"}
      )

  defp settle("issues_resolved", %{issues: profile}),
    do:
      project_sweep(
        "issues_resolved",
        profile.accepted == [],
        %{status: "No unresolved #{profile.threshold}+ issues"},
        %{reason: "#{length(profile.accepted)} unresolved #{profile.threshold}+ issues"}
      )

  defp settle("story_issues_resolved", %{issues: profile}) do
    %{
      entity_type: "story",
      name: "story_issues_resolved",
      default: true,
      default_details:
        details(%{status: "No unresolved #{profile.threshold}+ issues on this story"}),
      except:
        Enum.map(profile.unresolved_by_story, fn {story_id, issues} ->
          %{
            entity_type: "story",
            entity_id: story_id,
            name: "story_issues_resolved",
            satisfied: false,
            details:
              details(%{
                reason:
                  "#{length(issues)} unresolved #{profile.threshold}+ issue(s) on this story",
                issues: Enum.map(issues, &"#{&1.severity}: #{&1.title}")
              })
          }
        end)
    }
  end

  # The eight file requirements, settled from one profile.
  #
  # Default satisfied, exceptions unsatisfied, and that direction is forced
  # rather than chosen: the satisfied details carry no per-entity data
  # ("spec file exists"), while every failure does — `expected_path` for a
  # missing file, which `RequirementsFormatter` renders and is the only thing
  # telling an agent where to write it, and `validation_errors` for an invalid
  # one. Per-entity data cannot ride on a sweep's default.
  #
  # The population selects itself. `Shadow.sweep/2` matches `name` and entity
  # type, and only entities whose template produces that requirement have a row
  # — so a `:schema` component with no review requirement is never touched by
  # `review_file`, without this needing to know the templates or the config
  # filter at all.
  defp settle(name, %{files: profile}) when is_map_key(@file_requirements, name) do
    {kind, role, entity_type} = Map.fetch!(@file_requirements, name)

    %{
      entity_type: entity_type,
      name: name,
      default: true,
      default_details: details(satisfied_detail(kind, role)),
      except: file_failures(name, kind, role, entity_type, profile)
    }
  end

  # Three outcomes, and the default is the one most stories are in.
  #
  # `SpecsPassingChecker.passing?/3` takes them in order: not `specs_ready` is
  # an outright failure; `specs_ready` with no fresh spex run passes, because
  # there is nothing to re-check against; `specs_ready` with a fresh run passes
  # only if none of this story's own spec files are failing.
  #
  # So the sweep defaults to the first — a story nobody has marked ready — and
  # names the ready ones, which are the few. The alternative, emitting every
  # story as an exception, is one write per story for a population that is
  # mostly in one state.
  defp settle("bdd_specs_passing", %{specs: profile}) do
    ready = for {story_id, true} <- profile.specs_ready, do: story_id

    %{
      entity_type: "story",
      name: "bdd_specs_passing",
      default: false,
      default_details: details(%{reason: "Specs have not gone green on a fresh spex run yet"}),
      except: Enum.map(ready, &ready_story_verdict(&1, profile))
    }
  end

  # The six project `path_exists` requirements.
  #
  # One entity each, so the sweep is one row and `except` is always empty — the
  # shape is kept anyway so every requirement settles through one path.
  defp settle(name, %{files: profile}) when is_map_key(@path_requirements, name) do
    {satisfied?, detail} = path_verdict(Map.fetch!(@path_requirements, name), profile)
    project_sweep(name, satisfied?, detail, detail)
  end

  # `tests_passing`, the one requirement reading two profiles: whether the
  # component has a test file at all, and how many exunit problems it carries.
  #
  # `analysis_source` rides in the details deliberately — `RequirementGraph.serve/2`
  # reads it to mark the node stale when the exunit run predates the code, which
  # is applied at read time and is why this verdict does not need to know about
  # freshness itself.
  defp settle("tests_passing", %{files: files, problems: problems}) do
    %{
      entity_type: "component",
      name: "tests_passing",
      default: true,
      default_details: details(%{status: "No test failures", analysis_source: "exunit"}),
      except: tests_failures(files, problems)
    }
  end

  # A story's component link is satisfied when the named component *exists*,
  # not when the field is merely set — `component_exists_details/2` draws that
  # line, and it matters because a component id is a pure function of project
  # and module name, so a story can name one that has never synced.
  defp settle("component_linked", %{links: profile}) do
    %{
      entity_type: "story",
      name: "component_linked",
      default: false,
      default_details: details(%{reason: "component_id is not set"}),
      except: component_link_verdicts(profile)
    }
  end

  # `deployed_verdict/3`'s wording, which is not `Deploys.uat_check/2`'s: the
  # `:deployed` check type interpolates the environment and lowercases, and a
  # row this settles has to read like one a recompute settled.
  defp settle("deploy", %{links: profile}) do
    %{
      entity_type: "story",
      name: "deploy",
      default: false,
      default_details:
        details(%{status: "not deployed to uat, or deployed without a passing health check"}),
      except: deploy_verdicts(profile)
    }
  end

  defp satisfied_detail(:exists, role), do: %{status: "#{role} file exists"}
  defp satisfied_detail(:valid, role), do: %{status: "#{role} file valid"}

  defp file_failures(name, kind, role, "component", profile) do
    for component <- profile.components,
        verdict =
          file_verdict(kind, role, Map.get(profile.by_component_role, {component.id, role})),
        verdict != :ok,
        do:
          change(
            "component",
            component.id,
            name,
            false,
            failure_detail(verdict, role, expected_path(profile, component, role))
          )
  end

  defp file_failures(name, kind, role, "story", profile) do
    for story_id <- profile.story_ids,
        verdict = file_verdict(kind, role, Map.get(profile.by_story_role, {story_id, role})),
        verdict != :ok,
        do: change("story", story_id, name, false, failure_detail(verdict, role, nil))
  end

  # `has_role?/3` and `has_valid_role?/2`, as data. Existence asks only whether
  # a row is there; validity distinguishes three failures, and `valid: nil` —
  # scanned but not yet parsed — is deliberately not the same as invalid.
  defp file_verdict(:exists, _role, nil), do: :missing
  defp file_verdict(:exists, _role, _file), do: :ok
  defp file_verdict(:valid, _role, nil), do: :missing
  defp file_verdict(:valid, _role, %{valid: true}), do: :ok
  defp file_verdict(:valid, _role, %{valid: false} = file), do: {:invalid, file.validation_errors}
  defp file_verdict(:valid, _role, _file), do: :unvalidated

  defp failure_detail(:missing, role, nil), do: %{reason: "#{role} file missing"}

  defp failure_detail(:missing, role, path),
    do: %{reason: "#{role} file missing", expected_path: path}

  defp failure_detail({:invalid, errors}, role, _path),
    do: %{reason: "#{role} file invalid", errors: errors}

  defp failure_detail(:unvalidated, role, _path),
    do: %{reason: "#{role} file not yet validated"}

  defp expected_path(profile, component, role) do
    case Map.get(@expected_file_key, role) do
      nil ->
        nil

      key ->
        component
        |> CodeMySpec.Utils.component_files(profile.project)
        |> Map.get(key)
    end
  end

  defp ready_story_verdict(story_id, %{spex_fresh?: false}),
    do:
      change(
        "story",
        story_id,
        "bdd_specs_passing",
        true,
        %{status: "Specs ready (no fresh spex run to re-check against)"}
      )

  defp ready_story_verdict(story_id, profile) do
    case Map.get(profile.failing_by_story, story_id, []) do
      [] ->
        change("story", story_id, "bdd_specs_passing", true, %{
          status: "Specs ready and green on the current spex run"
        })

      failing ->
        change("story", story_id, "bdd_specs_passing", false, %{
          reason:
            "Marked specs-ready, but #{length(failing)} of this story's own specs " <>
              "are failing on the current spex run"
        })
    end
  end

  defp change(entity_type, entity_id, name, satisfied, detail_map),
    do: %{
      entity_type: entity_type,
      entity_id: entity_id,
      name: name,
      satisfied: satisfied,
      details: details(detail_map)
    }

  # `check_path_exists/3`: a tracked row, and a row whose `valid` is explicitly
  # false is a failure while `nil` — scanned, not yet parsed — is not.
  defp path_verdict({:path, path}, profile) do
    case Map.get(profile.by_path, path) do
      nil ->
        {false, %{reason: "File missing: #{path}"}}

      %{valid: false} = file ->
        {false, %{reason: "File invalid: #{path} — #{describe_errors(file.validation_errors)}"}}

      _file ->
        {true, %{path: path}}
    end
  end

  # `check_path_prefix/3`. Matched in Elixir rather than with a `LIKE` for the
  # reason `prefix_count/3` gives: `_` is a single-character wildcard in both
  # Postgres and SQLite, and a prefix containing one would quietly over-match.
  defp path_verdict({:prefix, prefix}, profile) do
    case Enum.count(profile.all, &String.starts_with?(&1.path, prefix)) do
      0 -> {false, %{reason: "No files at #{prefix}"}}
      n -> {true, %{status: "#{n} file(s) at #{prefix}"}}
    end
  end

  defp tests_failures(files, problems) do
    for component <- files.components,
        verdict = tests_verdict(component, files, problems),
        verdict != :ok,
        do: change("component", component.id, "tests_passing", false, tests_detail(verdict))
  end

  # A component with no test file fails before the count is consulted, which is
  # the order `check/5` takes them in — "No test file exists yet" rather than a
  # vacuous zero.
  defp tests_verdict(component, files, problems) do
    if Map.has_key?(files.by_component_role, {component.id, :test}) do
      case problems.by_component_source |> Map.get(component.id, %{}) |> Map.get("exunit", 0) do
        0 -> :ok
        n -> {:failures, n}
      end
    else
      :no_test_file
    end
  end

  defp tests_detail(:no_test_file), do: %{reason: "No test file exists yet"}

  defp tests_detail({:failures, n}),
    do: %{reason: "#{n} test failure(s)", count: n, analysis_source: "exunit"}

  # The same rendering `format_validation_errors/1` produces, so a row this
  # settles reads like one a recompute settled.
  defp describe_errors(%{} = errors) when map_size(errors) > 0 do
    errors
    |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end

  defp describe_errors(_errors), do: "no details"

  # A project requirement has one entity, so its sweep is one row — expressed as
  # a sweep anyway so every requirement settles through the same path.
  #
  # No scope needed: `Shadow.sweep/2` matches on entity type, and there is only
  # ever one project row per vantage.
  defp project_sweep(name, satisfied?, satisfied_details, unsatisfied_details) do
    %{
      entity_type: "project",
      name: name,
      default: satisfied?,
      default_details: details(if(satisfied?, do: satisfied_details, else: unsatisfied_details)),
      except: []
    }
  end

  # The same shape the checkers return, because a row a handler settled has to
  # read like one a recompute settled — a verdict that agreed while explaining
  # itself differently is a difference somebody investigates later for nothing.
  defp details(map), do: Requirement.normalize_details(map)

  # Both non-default outcomes: a link that resolves, and one that names a
  # component nothing has synced. The unset case is the sweep's default.
  defp component_link_verdicts(profile) do
    for {story_id, component_id} <- profile.component_id_by_story,
        not is_nil(component_id) do
      if MapSet.member?(profile.component_ids, component_id) do
        change("story", story_id, "component_linked", true, %{
          status: "component_id is set",
          component_id: component_id
        })
      else
        change("story", story_id, "component_linked", false, %{
          reason:
            "component #{component_id} does not exist yet — it is named correctly and " <>
              "appears when the working copy syncs the module it projects from",
          component_id: component_id
        })
      end
    end
  end

  # `Deploys.healthy?/1` decides, rather than a second reading of the row here,
  # so the handler and the checker cannot disagree about what counts as
  # deployed — the distinction the node exists to make.
  defp deploy_verdicts(profile) do
    for {story_id, deploy} <- profile.uat_deploy_by_story,
        Deploys.healthy?(deploy),
        do:
          change("story", story_id, "deploy", true, %{
            status: "deployed to uat and health-verified"
          })
  end
end
