defmodule CodeMySpec.Requirements.Handlers do
  @moduledoc """
  Domain events applied to the projection, without re-deriving anything.

  Three tables and a lookup:

    * `@dirties` — which profiles an event kind invalidates.
    * `@requirement_profiles` — which profiles move each requirement, and which
      it reads.
    * `settle/3` — one clause per requirement, reading its profile.

  Each dirtied profile is loaded once (`Profiles.load/2`) and every requirement
  it moves is settled from it in memory, across every entity at once: a default
  for the population, plus the exceptions the profile names. Adding a
  requirement is a `settle/3` clause and a row in `@requirement_profiles`;
  adding a source is a profile.

  `:no_handler` means nothing here knows the event, and the caller falls back to
  invalidating and recomputing. `{:ok, [], []}` is a different answer: the event
  moved nothing the graph reads. Collapsing the two would let an uninteresting
  event skip work it owed.

  See knowledge/requirements_graph, "Verdicts and handlers".
  """

  alias CodeMySpec.Deploys
  alias CodeMySpec.Epics
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Promotion.RunningCopy
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Requirements.ArchitectureChecker
  alias CodeMySpec.Requirements.BddRulesChecker
  alias CodeMySpec.Requirements.DevopsSetupChecker
  alias CodeMySpec.Requirements.DispatchChecker
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.IssuesChecker
  alias CodeMySpec.Requirements.PersonasChecker
  alias CodeMySpec.Requirements.Profiles
  alias CodeMySpec.Requirements.QaDocumentChecker
  alias CodeMySpec.Requirements.QaIntegrationPlanChecker
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
    # A sync moves only persona files on the server: a copy's file verdicts
    # are its overlay (`CopyOverlay`), read, never settled here.
    "files_synced" => [:personas],
    "qa_document_changed" => [:qa_documents],
    "deploy_changed" => [:links],
    # A setup step, environment or option changing moves what an undeployed
    # story's `deploy` is waiting on.
    "devops_setup_changed" => [:links],
    # A story row moves `:stories` (seal, `promoted_version`, `qa_ready_commit`,
    # `ready_for_dev`, `epic_id`), `:links` (`component_id`) and `:issues`
    # (issues are filtered by the story's `working_copy_id`). Not `:qa`.
    # Creation, deletion and readiness change which rows exist, and handlers
    # only settle rows, so those kinds are not handled.
    "story_changed" => [:stories, :links, :issues],
    # A reviewed failure can return issue submissions and clear certification.
    # This event is emitted after the outer QA transaction commits.
    "qa_attempt_submitted" => [:qa, :issues, :stories],
    # Settles `architecture_designed` (the orphan rule reads the component
    # set). The component's own rows can change with its template, so these
    # are `@partial`: their fallback marks stay for a narrow recompute.
    "component_created" => [:architecture],
    "component_changed" => [:architecture],
    "component_deleted" => [:architecture],
    # Moves edges, no verdict. Handled so its marks skip a recompute nothing
    # reads; in `@shape` so the projector redraws the edges.
    "dependency_changed" => []
  }

  # Handled kinds whose handler answers only part of what the event moved.
  # `IncrementalGraph.apply_handlers/2` drops an invalidation beside a handled
  # event as answered; for these it keeps it, so the entities the event named
  # still go through `compute_entity/4`.
  @partial ~w(component_created component_changed component_deleted issue_created issue_accepted issue_dismissed issue_resolved issue_updated qa_attempt_submitted)

  @doc "The handled kinds whose fallback marks still apply."
  @spec partial_kinds() :: [String.t()]
  def partial_kinds, do: @partial

  @doc "Story issue events can change node membership; project issue events only settle verdicts."
  def partial_event?(%{kind: "issue_created", payload: %{"status" => "incoming"}}), do: false

  def partial_event?(%{kind: "issue_" <> _, payload: payload}) do
    not is_nil(Map.get(payload || %{}, "story_id"))
  end

  def partial_event?(%{kind: kind}), do: kind in @partial

  @doc """
  Whether a partial event's fallback only re-establishes issue nodes, which are
  stored once per project: recomputed at one vantage, it is done at all.
  """
  def fallback_project_wide?(%{kind: "issue_" <> _}), do: true
  def fallback_project_wide?(_mark), do: false

  # Handled kinds that can move the shape the edges are drawn from (a
  # dependency, a story relinked). The projector asks the shape whether to
  # redraw edges. Component kinds go that way already through `@partial`.
  @shape ~w(dependency_changed story_changed)

  @doc "The handled kinds after which the projector checks the shape."
  @spec shape_kinds() :: [String.t()]
  def shape_kinds, do: @shape

  @doc """
  The event kinds this module can apply.

  Read by `every_declared_event_is_applied_or_counted_test` against
  `GraphInputs.kinds/0`, so a kind that is declared and unhandled has to be
  written down as falling back rather than discovered as a cost.
  """
  @spec handled_kinds() :: [String.t()]
  def handled_kinds, do: Map.keys(@dirties)

  # A kind belongs in `@dirties` only once its handlers settle everything that
  # event can move, or mark it `@partial`: handling discards the fallback marks,
  # so an unsettled requirement keeps a stale verdict forever.
  # See knowledge/requirements_graph, "Lessons".

  # What each requirement is moved by, and what its `settle/3` clause reads:
  # one list when they agree, `{moved_by, reads}` when a rollup is moved by more
  # than it reads (`personas_complete`). Each profile loads once per event.
  @requirement_profiles %{
    "issues_triaged" => [:issues],
    "issues_resolved" => [:issues],
    "story_issues_triaged" => [:issues],
    "ready_for_qa" => [:stories],
    # Stored QA documents; the clauses read the documents themselves.
    "qa_setup" => {[:qa_documents], []},
    "qa_journey_plan" => {[:qa_documents], []},
    "component_linked" => [:links],
    "deploy" => [:links],
    "three_amigos_complete" => [:stories],
    "questions_answered" => [:stories],
    # Issues too: a fix resolved after the last promotion unsatisfies it.
    "story_promoted" => [:stories, :issues],
    # Cited issues can release a partial/fail without changing its certification.
    # Story changes also move the certification the attempt must answer for.
    "qa_complete" => {[:qa, :stories, :issues], [:qa, :stories]},
    # The rollups, which query for themselves — see `@delegate_requirements`.
    # The profile carries a persona's `summary.md` and `sources.md` files.
    "personas_complete" => [:personas],
    "stories_exist" => [:stories],
    "work_dispatched" => [:stories, :issues]
  }

  # Rollups no event carries the answer to, settled by calling the
  # requirement's own checker once: a narrowed recompute, right by construction
  # because it is the recompute's function. `{module, function}` as in each
  # definition's config; `QaIntegrationPlanChecker` returns the looser delegate
  # shape, mapped by `RequirementCalculator.normalize_delegate_result/1`.
  @delegate_requirements %{
    "spex_boundary_ready" => {SpexBoundaryChecker, :complete?},
    "personas_complete" => {PersonasChecker, :complete?},
    "architecture_designed" => {ArchitectureChecker, :complete?},
    "stories_exist" => {StoriesChecker, :exist?},
    "work_dispatched" => {DispatchChecker, :dispatched?},
    "qa_integration_plan" => {QaIntegrationPlanChecker, :delegate}
  }

  @doc """
  Every requirement name this module can settle from an event, from
  `@requirement_profiles` and `@delegate_requirements`. A definition in
  neither is never settled by a handled event.
  """
  @spec settleable_requirement_names() :: [String.t()]
  def settleable_requirement_names,
    do: Map.keys(@requirement_profiles) ++ Map.keys(@delegate_requirements)

  # Component work is the presence of its implementation file.
  @file_requirements %{
    "implementation_file" => {:exists, :implementation, "component"}
  }

  # The five project `path_exists` requirements, by what they look for.
  @path_requirements %{
    "technical_strategy" => {:path, ".code_my_spec/architecture/decisions.md"},
    "code_generation" => {:path, ".code_my_spec/tasks/code_generation.sh"},
    "qa_journey_execute" => {:path, ".code_my_spec/qa/journey_result.md"}
  }

  # Which file key `Utils.component_files/2` holds the expected path under.
  # `has_role?/3`'s own mapping, and `nil` for a role with no canonical place —
  # a `:bdd_spec` path is assigned per criterion, not derived from the module.
  @expected_file_key %{
    implementation: :code_file,
    test: :test_file
  }

  @doc """
  What this event does to the projection.

  `{:ok, changes, sweeps}` — individual rows to set, and requirements to settle
  across a whole population. `skip` names requirements already settled this
  drain: a project-wide one is the same at every checkout.
  """
  @spec apply_event(Scope.t(), String.t(), map(), [String.t()]) ::
          {:ok, [change()], [sweep()]} | :no_handler
  def apply_event(%Scope{} = scope, kind, _payload, skip \\ []) do
    case Map.get(@dirties, kind) do
      nil ->
        :no_handler

      dirty ->
        names = requirements_reading(dirty) -- skip
        profiles = load_profiles(scope, names)

        {:ok, [], Enum.map(names, &settle(&1, profiles, scope))}
    end
  end

  # What only a checkout's own files answer: its harness reports these.
  @copy_names ~w(
    implementation_file bdd_specs_exist technical_strategy code_generation
    qa_journey_execute spex_boundary_ready architecture_designed qa_integration_plan
  )

  @doc """
  A checkout's file verdicts, settled from profiles alone: `:files` (see
  `Profiles.files_profile/4`), `:stories` with `amigos.criteria_by_story`, and
  `:architecture`. Reads no database, so a harness runs it on its own scan.
  """
  @spec copy_verdicts(map()) :: [sweep()]
  def copy_verdicts(profiles), do: Enum.map(@copy_names, &settle(&1, profiles, nil))

  # Records, but a checkout's own: its issues leave out those on stories placed
  # at another checkout.
  @gate_names ~w(issues_triaged issues_resolved work_dispatched)

  @doc """
  The checkout's three placement-filtered gates, settled now from its issues
  and the project's stories. Cheap enough to answer on read.
  """
  @spec gate_verdicts(Scope.t()) :: [sweep()]
  def gate_verdicts(%Scope{} = scope) do
    profiles = %{issues: Profiles.load(scope, :issues), stories: Profiles.load(scope, :dispatch)}
    Enum.map(@gate_names, &settle(&1, profiles, scope))
  end

  @doc "The requirement names `gate_verdicts/1` settles."
  @spec gate_names() :: [String.t()]
  def gate_names, do: @gate_names

  @doc "The requirement names `copy_verdicts/1` settles."
  @spec copy_names() :: [String.t()]
  def copy_names, do: @copy_names

  @doc """
  Whether everything this kind moves is stored once per project: settled at one
  checkout, it is settled at all of them.
  """
  @spec project_wide?(String.t() | nil) :: boolean()
  def project_wide?(kind) do
    case Map.get(@dirties, kind) do
      nil -> false
      dirty -> kind not in @shape and requirements_reading(dirty) -- project_names() == []
    end
  end

  defp project_names, do: GraphStore.project_wide_names()

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
        %{status: IssuesChecker.triaged_status(profile.threshold)},
        %{reason: IssuesChecker.untriaged_reason(length(profile.incoming), profile.threshold)}
      )

  defp settle("issues_resolved", %{issues: profile}, _scope),
    do:
      project_sweep(
        "issues_resolved",
        profile.accepted == [],
        %{status: "No unresolved #{profile.threshold}+ issues"},
        %{reason: "#{length(profile.accepted)} unresolved #{profile.threshold}+ issues"}
      )

  defp settle("story_issues_triaged", %{issues: profile}, _scope) do
    %{
      entity_type: "story",
      name: "story_issues_triaged",
      default: true,
      default_details: details(%{status: IssuesChecker.story_triaged_status()}),
      except:
        Enum.map(profile.incoming_by_story, fn {story_id, issues} ->
          %{
            entity_type: "story",
            entity_id: story_id,
            name: "story_issues_triaged",
            satisfied: false,
            details: details(IssuesChecker.story_untriaged_details(issues))
          }
        end)
    }
  end

  # `implementation_file`. Default satisfied, failures as exceptions — forced:
  # every failure carries per-entity data (`expected_path`, `validation_errors`)
  # and a sweep's default cannot. Only entities whose template produces the
  # requirement have a row, so the population selects itself.
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

  # The stamp `ReadyForQa` writes, read the way `story_promoted` reads
  # `promoted_version`: a story column, nothing about analysis. Unset is the
  # common state, so it is the default and the stamped stories are named.
  defp settle("ready_for_qa", %{stories: profile}, _scope) do
    %{
      entity_type: "story",
      name: "ready_for_qa",
      default: false,
      default_details: details(%{reason: "qa_ready_commit is not set"}),
      except:
        for %{qa_ready_commit: commit, id: id} <- profile.stories, is_binary(commit) do
          change("story", id, "ready_for_qa", true, %{
            status: "Certified ready for QA at #{commit}",
            qa_ready_commit: commit
          })
        end
    }
  end

  # Per criterion, from `RequirementCalculator.bdd_specs_covered/3` — the
  # recompute's own function, so the two cannot disagree. Default unsatisfied:
  # a story with no criteria is unsatisfied with nothing per story to say.
  # See knowledge/requirements_graph, "Lessons".
  defp settle("bdd_specs_exist", %{files: files, stories: stories}, _scope) do
    %{
      entity_type: "story",
      name: "bdd_specs_exist",
      default: false,
      default_details: details(%{reason: "no acceptance criteria on this story"}),
      except: bdd_spec_verdicts(stories, files)
    }
  end

  defp settle("qa_setup", _profile, scope) do
    {satisfied?, detail} = QaDocumentChecker.plan?(scope, nil)
    project_sweep("qa_setup", satisfied?, detail, detail)
  end

  defp settle("qa_journey_plan", _profile, scope) do
    {satisfied?, detail} = QaDocumentChecker.journey_plan?(scope, nil)
    project_sweep("qa_journey_plan", satisfied?, detail, detail)
  end

  # The remaining project `path_exists` requirements: one row each, `except` empty.
  defp settle(name, %{files: profile}, _scope) when is_map_key(@path_requirements, name) do
    {satisfied?, detail} = path_verdict(Map.fetch!(@path_requirements, name), profile)
    project_sweep(name, satisfied?, detail, detail)
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

  # `DevopsSetupChecker.undeployed/2`, the same details the recompute writes,
  # so an undeployed story waits on missing setup on either path.
  defp settle("deploy", %{links: profile}, _scope) do
    %{
      entity_type: "story",
      name: "deploy",
      default: false,
      default_details: details(DevopsSetupChecker.undeployed("uat", profile.uat_setup_missing)),
      except: deploy_verdicts(profile)
    }
  end

  # A seal is a record and stays sealed, so the default is sealed and the
  # unsealed few are named with their gap. No re-read like `sealed?/2`: the
  # profile is read after the event that prompted it.
  defp settle("three_amigos_complete", %{stories: profile}, scope) do
    %{
      entity_type: "story",
      name: "three_amigos_complete",
      default: true,
      default_details: details(%{status: "Three Amigos sealed"}),
      except: unsealed_verdicts(profile, scope)
    }
  end

  # From the preloaded `profile.amigos.questions_by_story`: one read per event,
  # not one per story.
  defp settle("questions_answered", %{stories: profile}, _scope) do
    %{
      entity_type: "story",
      name: "questions_answered",
      default: true,
      default_details: details(%{status: "No open questions"}),
      except: open_question_verdicts(profile)
    }
  end

  # Default: never promoted. Exceptions: stories carrying a version, with
  # `RunningCopy`'s verdict (mostly about which copy runs and whether it
  # serves), in two reads rather than two per story.
  defp settle("story_promoted", %{stories: profile}, scope) do
    {{default?, default_details}, promoted} =
      RunningCopy.running_copy_verdicts(scope, profile.stories)

    %{
      entity_type: "story",
      name: "story_promoted",
      default: default?,
      default_details: details(default_details),
      except: promoted_verdicts(promoted)
    }
  end

  # The newest attempt decides, by `Verdict`'s rules (a later `:partial`
  # overrides a pass; an invalidated pass is not one). Default unsatisfied: no
  # attempt is the common state and reads like a failed one.
  defp settle("qa_complete", %{qa: profile, stories: stories}, scope),
    do: %{
      entity_type: "story",
      name: "qa_complete",
      default: false,
      default_details: details(elem(Verdict.verdict(false), 1)),
      except: qa_passes(profile, stories, scope)
    }

  # The rollups: one call to the requirement's own checker (`@delegate_requirements`).
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

  # One project row per vantage, still a sweep so every requirement settles one
  # way. No scope needed: `GraphStore.sweep/2` matches on entity type.
  defp project_sweep(name, satisfied?, satisfied_details, unsatisfied_details) do
    %{
      entity_type: "project",
      name: name,
      default: satisfied?,
      default_details: details(if(satisfied?, do: satisfied_details, else: unsatisfied_details)),
      except: []
    }
  end

  # The checkers' shape: a row a handler settled must read like one a recompute
  # settled.
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
      {QaIntegrationPlanChecker, :delegate} ->
        # Handed the profile's files so it does not re-read them;
        # `integration_files/2` takes a context in exactly this shape.
        scope
        |> QaIntegrationPlanChecker.evaluate(nil, %{files_by_project: profiles.files.all})
        |> RequirementCalculator.normalize_delegate_result()

      {PersonasChecker, :complete?} ->
        PersonasChecker.complete?(scope, scope.active_project, profiles.personas)

      {DispatchChecker, :dispatched?} ->
        DispatchChecker.verdict(dispatch_state(profiles))

      {SpexBoundaryChecker, :complete?} ->
        # The profile already holds every file this checkout has.
        SpexBoundaryChecker.complete?(scope, nil, %{files_by_project: profiles.files.all})

      {StoriesChecker, :exist?} ->
        StoriesChecker.verdict(profiles.stories.stories != [])

      {ArchitectureChecker, :complete?} ->
        ArchitectureChecker.complete?(
          scope,
          nil,
          Map.put(profiles.architecture, :files_by_project, profiles.files.all)
        )

      {module, function} ->
        apply(module, function, [scope, scope.active_project])
    end
  end

  # `Epics.dispatch_state/1`'s three answers, from the profiles.
  defp dispatch_state(%{stories: %{epic_in_progress?: true}}),
    do: {:nothing_to_assign, :in_progress}

  defp dispatch_state(%{stories: %{stories: stories}, issues: issues}),
    do:
      Epics.awaiting_dispatch(
        stories,
        Enum.filter(
          issues.accepted,
          &(not is_nil(&1.story_id) and Issue.fix_offered?(&1, issues.threshold))
        )
      )

  # The unsealed stories, each with its gap. Worded by
  # `BddRulesChecker.unsealed_reason/3` from the profile's context, not the four
  # queries per story `sealed?/2` costs.
  defp unsealed_verdicts(profile, scope) do
    for %{three_amigos_sealed: sealed} = story <- profile.stories,
        sealed != true do
      {false, detail} = BddRulesChecker.unsealed_reason(scope, story, profile.amigos)
      change("story", story.id, "three_amigos_complete", false, detail)
    end
  end

  # The stories with at least one open question, each naming them — mirrors
  # `unsealed_verdicts/2`'s shape exactly, reading the same preloaded map
  # rather than querying per story.
  defp open_question_verdicts(profile) do
    for story <- profile.stories,
        open = open_questions(profile.amigos.questions_by_story, story.id),
        open != [] do
      detail =
        details(%{
          reason: "#{length(open)} open question(s): " <> Enum.map_join(open, "; ", & &1.text)
        })

      change("story", story.id, "questions_answered", false, detail)
    end
  end

  defp open_questions(questions_by_story, story_id) do
    questions_by_story
    |> Map.get(story_id, [])
    |> Enum.filter(&(&1.status == :open))
  end

  # A promoted story keeps `Promotion`'s answer, which is not always satisfied:
  # a stamped story on a checkout whose application is down still fails, because
  # there is nothing for QA to test.
  defp promoted_verdicts(promoted) do
    for {story_id, {satisfied?, detail}} <- promoted,
        do: change("story", story_id, "story_promoted", satisfied?, detail)
  end

  # One verdict per story that has criteria. Every spex on the copy, not just
  # the story's: a file covers a criterion by the number it names.
  defp bdd_spec_verdicts(stories, files) do
    specs = Enum.filter(files.all, &(&1.role == :bdd_spec))

    for {story_id, criteria} <- stories.amigos.criteria_by_story, criteria != [] do
      {satisfied?, detail} = RequirementCalculator.bdd_specs_covered(criteria, specs, :bdd_spec)

      change("story", story_id, "bdd_specs_exist", satisfied?, detail)
    end
  end

  # Use the same review identity check as the ordinary graph computation.
  #
  # A false verdict with `waiting_on` (story 1116, criterion 2196: the last
  # partial/fail attempt cited an issue still open, however it is triaged now)
  # gets its own row too â every other false story shares `default_details`,
  # but a reason naming which issue holds this one is not every story's reason.
  defp qa_passes(profile, %{stories: stories}, scope) do
    ctx = %{
      qa_latest_by_story: profile.latest_by_story,
      qa_issues_by_id: profile.issues_by_id,
      qa_issue_threshold: profile.issue_threshold
    }

    ctx =
      case Map.fetch(profile, :submission_snapshots) do
        {:ok, snapshots} -> Map.put(ctx, :qa_submission_snapshots, snapshots)
        :error -> ctx
      end

    for story <- stories,
        {satisfied?, detail} = Verdict.complete_check(scope, story, ctx),
        satisfied? or Map.has_key?(detail, :waiting_on) do
      change("story", story.id, "qa_complete", satisfied?, detail)
    end
  end
end
