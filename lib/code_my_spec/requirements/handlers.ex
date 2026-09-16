defmodule CodeMySpec.Requirements.Handlers do
  @moduledoc """
  Domain events applied to the projection, without re-deriving anything.

  ## The shape

  Three tables and a lookup function, which is the whole of it:

    * `@dirties` — which profiles an event kind invalidates.
    * `@requirement_profiles` — which profiles each requirement is moved by, and
      which it reads.
    * `settle/3` — one clause per requirement, reading its profile.

  An event dirties one or more profiles, each profile is loaded once
  (`Profiles.load/2`), and every requirement those profiles move is settled from
  it in memory. Adding a requirement is a `settle/3` clause and a row in
  `@requirement_profiles`. Adding a source is a profile.

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

  alias CodeMySpec.AgentTasks.QaIntegrationPlan
  alias CodeMySpec.Deploys
  alias CodeMySpec.Promotion
  alias CodeMySpec.Qa
  alias CodeMySpec.Qa.QaAttempts
  alias CodeMySpec.Requirements.ArchitectureChecker
  alias CodeMySpec.Requirements.BddRulesChecker
  alias CodeMySpec.Requirements.DispatchChecker
  alias CodeMySpec.Requirements.PersonasChecker
  alias CodeMySpec.Requirements.Profiles
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.SpexBoundaryChecker
  alias CodeMySpec.Requirements.StoriesChecker
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
    # Safe again: the four project delegates a sync moves —
    # `spex_boundary_ready`, `qa_integration_plan`, `personas_complete` and
    # `architecture_designed` — now have `settle/3` clauses, so nothing this
    # event moves is left to the marks it discards.
    "files_synced" => [:files, :specs],
    # Problems feed `tests_passing` *and* `bdd_specs_passing` — a story's own
    # failing spex specs are problem rows — so both profiles, or the story
    # verdict is left behind by a run that changed it.
    "problems_changed" => [:problems, :specs],
    "deploy_changed" => [:links],
    # A story row reaches five profiles, which is why this event took five
    # conversions to turn on:
    #
    #   * `:stories`  — the seal, `promoted_version`, `ready_for_dev`, `epic_id`
    #   * `:links`    — `component_id`, which `component_linked` resolves
    #   * `:specs`    — `specs_ready`, the first thing `bdd_specs_passing` asks
    #   * `:issues`   — `exclude_other_copies_stories/2` filters issues by the
    #                   story's `working_copy_id`, so moving a story between
    #                   checkouts moves which issues gate here
    #   * `:qa`       — no. A story row says nothing about its QA attempts.
    #
    # Creation and deletion are `story_created` / `story_deleted`, which nothing
    # handles, and so is `story_readiness_changed`: `ready_for_dev` decides
    # whether a story projects at all, and handlers settle rows rather than
    # writing them.
    "story_changed" => [:stories, :links, :specs, :issues],
    "qa_attempt_submitted" => [:qa]
  }

  # ## What is deliberately not here
  #
  # An event kind may only appear in `@dirties` once its handlers settle
  # **everything that event can move**. Handling it discards the fallback marks
  # by observation id, so any requirement left unsettled keeps whatever verdict
  # it already had, with nothing to correct it.
  #
  # The shadow diff caught this on `story_changed`: sealing a story moves
  # `three_amigos_complete`, no handler settles it, and the diff came back
  # `disagree story:9058/three_amigos_complete`.
  #
  #   * `component_changed` — a component's type decides which template applies,
  #     so it can change which requirements exist, and only a recompute writes
  #     rows that were not there.
  #
  # It falls back to invalidation, which costs a narrow recompute and is
  # correct. The unit of conversion is an event and its whole requirement set,
  # never a requirement on its own.

  # What each requirement is moved by, and what its `settle/3` clause reads.
  #
  # Declared per requirement rather than per profile, because `tests_passing`
  # reads two — whether the component has a test file at all, and how many
  # exunit problems it has — and a table keyed the other way cannot say that.
  #
  # Usually the two are the same list, which is the bare-list shape. They come
  # apart for the rollups in `@delegate_requirements`, written
  # `{moved_by, reads}`: `architecture_designed` is moved by files *and* by
  # stories — it expands a dependency graph and reports released stories with no
  # component — while its clause calls `ArchitectureChecker`, which queries for
  # itself and reads no profile at all. Collapsing the two would put the 120ms
  # file read on every story update to hand a checker data it ignores.
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
    # Files for the spec paths, stories for the criteria those paths have to
    # cover. Not a `@file_requirements` row any more — see its `settle/3`.
    "bdd_specs_exist" => [:files, :stories],
    "technical_strategy" => [:files],
    "code_generation" => [:files],
    "qa_setup" => [:files],
    "qa_journey_plan" => [:files],
    "qa_journey_execute" => [:files],
    "qa_journey_wallaby" => [:files],
    "tests_passing" => [:files, :problems],
    "component_linked" => [:links],
    "deploy" => [:links],
    "three_amigos_complete" => [:stories],
    "code_on_running_copy" => [:stories],
    "qa_complete" => [:qa],
    # The rollups. `qa_integration_plan` is handed the file profile it would
    # otherwise re-read; the rest query for themselves — see
    # `@delegate_requirements`.
    "qa_integration_plan" => [:files],
    "spex_boundary_ready" => {[:files], []},
    "personas_complete" => {[:files], []},
    "architecture_designed" => {[:files, :stories], []},
    "stories_exist" => {[:stories], []},
    "work_dispatched" => {[:stories], []}
  }

  # Requirements whose verdict is a rollup no event determines.
  #
  # `architecture_designed` expands a dependency graph to find orphan contexts;
  # `personas_complete` checks two artifacts per persona; `spex_boundary_ready`
  # asks five questions about four directories; `qa_integration_plan` validates
  # an index against the specs it names. None of those is a value an event
  # carries — a file landing does not *say* whether the architecture is clean.
  #
  # So these are settled by calling the requirement's own checker once, which is
  # honestly a narrowed recompute rather than event application. The win is the
  # narrowing: one requirement instead of all fourteen project requirements plus
  # every entity, and correct by construction because it is the same function
  # the recompute calls.
  #
  # `work_dispatched` and `stories_exist` are here for the same reason and are
  # cheaper about it: two or three reads each, none of them per story.
  #
  # `{module, function}`, matching the `config: %{module:, function:}` each
  # definition already carries. `QaIntegrationPlan` is the exception — it
  # returns the looser delegate shape that
  # `RequirementCalculator.normalize_delegate_result/1` maps, which is public
  # for exactly this reason: a second copy of that mapping is the copy that
  # drifts.
  @delegate_requirements %{
    "spex_boundary_ready" => {SpexBoundaryChecker, :complete?},
    "personas_complete" => {PersonasChecker, :complete?},
    "architecture_designed" => {ArchitectureChecker, :complete?},
    "stories_exist" => {StoriesChecker, :exist?},
    "work_dispatched" => {DispatchChecker, :dispatched?},
    "qa_integration_plan" => {QaIntegrationPlan, :delegate}
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
    "implementation_file" => {:exists, :implementation, "component"}
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

        {:ok, [], Enum.map(names, &settle(&1, profiles, scope))}
    end
  end

  # Every requirement at least one of the dirtied profiles moves. A requirement
  # moved by two is settled once, not once per profile.
  defp requirements_reading(dirty) do
    for {name, entry} <- @requirement_profiles,
        Enum.any?(moved_by(entry), &(&1 in dirty)),
        do: name
  end

  # The union of what those requirements actually read, each loaded once however
  # many read it. This is the whole reason profiles are separate from handlers.
  defp load_profiles(scope, names) do
    names
    |> Enum.flat_map(&reads(Map.fetch!(@requirement_profiles, &1)))
    |> Enum.uniq()
    |> Map.new(&{&1, Profiles.load(scope, &1)})
  end

  defp moved_by({moved_by, _reads}), do: moved_by
  defp moved_by(both), do: both

  defp reads({_moved_by, reads}), do: reads
  defp reads(both), do: both

  # -- One clause per requirement. Each reads its profile and nothing else. --

  defp settle("issues_triaged", %{issues: profile}, _scope),
    do:
      project_sweep(
        "issues_triaged",
        profile.incoming == [],
        %{status: "No untriaged issues at #{profile.threshold}+ severity"},
        %{reason: "#{length(profile.incoming)} untriaged #{profile.threshold}+ issues"}
      )

  defp settle("issues_resolved", %{issues: profile}, _scope),
    do:
      project_sweep(
        "issues_resolved",
        profile.accepted == [],
        %{status: "No unresolved #{profile.threshold}+ issues"},
        %{reason: "#{length(profile.accepted)} unresolved #{profile.threshold}+ issues"}
      )

  defp settle("story_issues_resolved", %{issues: profile}, _scope) do
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
  defp settle(name, %{files: profile}, _scope) when is_map_key(@file_requirements, name) do
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
  defp settle("bdd_specs_passing", %{specs: profile}, _scope) do
    ready = for {story_id, true} <- profile.specs_ready, do: story_id

    %{
      entity_type: "story",
      name: "bdd_specs_passing",
      default: false,
      default_details: details(%{reason: "Specs have not gone green on a fresh spex run yet"}),
      except: Enum.map(ready, &ready_story_verdict(&1, profile))
    }
  end

  # Per criterion, not per story, and that distinction cost a silent regression.
  #
  # This was a `@file_requirements` row — "does this story have any file in the
  # `:bdd_spec` role" — which is what the requirement meant until `f97e1216d`
  # made it "does every criterion have one". The table did not follow. The
  # handler went on passing stories that had a spec file and uncovered
  # criteria, and no test caught it because the table was still internally
  # consistent; a diff against `RequirementCalculator` on a merged tree is what
  # found it, on every vantage at once.
  #
  # So the verdict comes from `RequirementCalculator.bdd_specs_covered/3` now,
  # which is the function the recompute calls. A requirement whose meaning can
  # change out from under a lookup table does not belong in one.
  #
  # Default unsatisfied, because a story with no criteria is unsatisfied and
  # its reason is the only one that carries nothing per story. Every story that
  # *has* criteria is an exception — up to the whole population — which costs
  # one statement now that `Shadow.put_verdicts/5` sends them as arrays.
  defp settle("bdd_specs_exist", %{files: files, stories: stories}, _scope) do
    %{
      entity_type: "story",
      name: "bdd_specs_exist",
      default: false,
      default_details: details(%{reason: "no acceptance criteria on this story"}),
      except: bdd_spec_verdicts(stories, files)
    }
  end

  # The six project `path_exists` requirements.
  #
  # One entity each, so the sweep is one row and `except` is always empty — the
  # shape is kept anyway so every requirement settles through one path.
  defp settle(name, %{files: profile}, _scope) when is_map_key(@path_requirements, name) do
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
  defp settle("tests_passing", %{files: files, problems: problems}, _scope) do
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
  defp settle("component_linked", %{links: profile}, _scope) do
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
  defp settle("deploy", %{links: profile}, _scope) do
    %{
      entity_type: "story",
      name: "deploy",
      default: false,
      default_details:
        details(%{status: "not deployed to uat, or deployed without a passing health check"}),
      except: deploy_verdicts(profile)
    }
  end

  # The seal, which is a record rather than a recomputation: once a Three Amigos
  # session is sealed it stays sealed, and a question raised against a story
  # that shipped months ago is the next conversation, not evidence that the last
  # one never happened.
  #
  # So the sweep defaults to sealed — the state most released stories are in,
  # and the only one whose detail carries nothing per story — and names the
  # unsealed few, whose detail is the gap they have not closed.
  #
  # No re-read on the negative path, which `sealed?/2` needs and this does not:
  # it re-reads because the struct in hand may predate a seal taken mid-request,
  # and the profile is a fresh read taken after the event that prompted it.
  defp settle("three_amigos_complete", %{stories: profile}, scope) do
    %{
      entity_type: "story",
      name: "three_amigos_complete",
      default: true,
      default_details: details(%{status: "Three Amigos sealed"}),
      except: unsealed_verdicts(profile, scope)
    }
  end

  # Promotion is a stamp on the story, so the sweep is the two states it has:
  # the default is every story that has never been promoted, and the exceptions
  # are the ones carrying a version.
  #
  # `Promotion` decides both. The question it answers is mostly about the
  # project — which copy is running, whether it is serving — and only the stamp
  # is per story, which is what `running_copy_verdicts/2` exists to say in two
  # reads rather than two per story.
  defp settle("code_on_running_copy", %{stories: profile}, scope) do
    {{default?, default_details}, promoted} =
      Promotion.running_copy_verdicts(scope, profile.stories)

    %{
      entity_type: "story",
      name: "code_on_running_copy",
      default: default?,
      default_details: details(default_details),
      except: promoted_verdicts(promoted)
    }
  end

  # The newest attempt decides, and `QaAttempts.passed?/1` decides what counts —
  # a later `:partial` overrides an earlier pass, and an invalidated pass is not
  # one. Default unsatisfied, because a story with no attempt at all is the
  # common state and reads identically to one whose latest attempt failed.
  defp settle("qa_complete", %{qa: profile}, _scope) do
    %{
      entity_type: "story",
      name: "qa_complete",
      default: false,
      default_details: details(elem(Qa.verdict(false), 1)),
      except: qa_passes(profile)
    }
  end

  # The rollups. One call to the requirement's own checker, which is a narrowed
  # recompute rather than event application — see `@delegate_requirements` for
  # why that is the honest description and why it is still worth doing.
  defp settle(name, profiles, scope) when is_map_key(@delegate_requirements, name) do
    {satisfied?, detail} = delegate_verdict(name, profiles, scope)
    project_sweep(name, satisfied?, detail, detail)
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
        {false,
         %{
           reason:
             "File invalid: #{path} — " <>
               RequirementCalculator.describe_validation_errors(file)
         }}

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

  defp delegate_verdict(name, profiles, scope) do
    case Map.fetch!(@delegate_requirements, name) do
      {QaIntegrationPlan, :delegate} ->
        # Handed the profile's files so it does not re-read them;
        # `integration_files/2` takes a context in exactly this shape.
        scope
        |> QaIntegrationPlan.evaluate(nil, %{files_by_project: profiles.files.all})
        |> RequirementCalculator.normalize_delegate_result()

      {module, function} ->
        apply(module, function, [scope, scope.active_project])
    end
  end

  # The unsealed stories, each with the gap it has not closed.
  #
  # `BddRulesChecker.unsealed_reason/3` produces the wording, from the context
  # the profile loaded rather than four queries per story — which is what
  # `sealed?/2` costs and why a 76-story project spent 304 queries deciding one
  # requirement.
  defp unsealed_verdicts(profile, scope) do
    for %{three_amigos_sealed: sealed} = story <- profile.stories,
        sealed != true do
      {false, detail} = BddRulesChecker.unsealed_reason(scope, story, profile.amigos)
      change("story", story.id, "three_amigos_complete", false, detail)
    end
  end

  # A promoted story keeps `Promotion`'s answer, which is not always satisfied:
  # a stamped story on a checkout whose application is down still fails, because
  # there is nothing for QA to test.
  defp promoted_verdicts(promoted) do
    for {story_id, {satisfied?, detail}} <- promoted,
        do: change("story", story_id, "code_on_running_copy", satisfied?, detail)
  end

  # One verdict per story that has criteria, from the files that vantage can see.
  #
  # Grouped by story rather than filtered to `:bdd_spec` here, because
  # `bdd_specs_covered/3` takes the entity's files and applies the role itself —
  # the same shape `RequirementCalculator` hands it.
  defp bdd_spec_verdicts(stories, files) do
    by_story = Enum.group_by(Enum.filter(files.all, & &1.story_id), & &1.story_id)

    for {story_id, criteria} <- stories.amigos.criteria_by_story, criteria != [] do
      {satisfied?, detail} =
        RequirementCalculator.bdd_specs_covered(
          criteria,
          Map.get(by_story, story_id, []),
          :bdd_spec
        )

      change("story", story_id, "bdd_specs_exist", satisfied?, detail)
    end
  end

  # Only the passes. The default already says what every other story's latest
  # attempt amounts to, and says it identically.
  defp qa_passes(profile) do
    for {story_id, attempt} <- profile.latest_by_story, QaAttempts.passed?(attempt) do
      {true, detail} = Qa.verdict(true)
      change("story", story_id, "qa_complete", true, detail)
    end
  end
end
