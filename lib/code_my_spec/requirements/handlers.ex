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
    "analysis_completed" => [:specs],
    "files_synced" => [:files]
  }

  # Which requirements each profile settles. Adding a requirement to a profile
  # already loaded costs nothing at read time.
  @fed_by %{
    issues: ["issues_triaged", "issues_resolved", "story_issues_resolved"],
    specs: ["bdd_specs_passing"],
    files: [
      "spec_file",
      "spec_valid",
      "test_file",
      "test_spec_alignment",
      "review_file",
      "review_valid",
      "implementation_file",
      "bdd_specs_exist"
    ]
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

      profile_names ->
        sweeps =
          profile_names
          |> Enum.flat_map(fn profile_name ->
            profile = Profiles.load(scope, profile_name)
            Enum.map(@fed_by[profile_name], &settle(&1, profile))
          end)

        {:ok, [], sweeps}
    end
  end

  # -- One clause per requirement. Each reads its profile and nothing else. --

  defp settle("issues_triaged", profile),
    do:
      project_sweep(
        "issues_triaged",
        profile.incoming == [],
        %{status: "No untriaged issues at #{profile.threshold}+ severity"},
        %{reason: "#{length(profile.incoming)} untriaged #{profile.threshold}+ issues"}
      )

  defp settle("issues_resolved", profile),
    do:
      project_sweep(
        "issues_resolved",
        profile.accepted == [],
        %{status: "No unresolved #{profile.threshold}+ issues"},
        %{reason: "#{length(profile.accepted)} unresolved #{profile.threshold}+ issues"}
      )

  defp settle("story_issues_resolved", profile) do
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
  defp settle(name, profile) when is_map_key(@file_requirements, name) do
    {kind, role, entity_type} = Map.fetch!(@file_requirements, name)

    %{
      entity_type: entity_type,
      name: name,
      default: true,
      default_details: details(satisfied_detail(kind, role)),
      except: file_failures(name, kind, role, entity_type, profile)
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
  defp settle("bdd_specs_passing", profile) do
    ready = for {story_id, true} <- profile.specs_ready, do: story_id

    %{
      entity_type: "story",
      name: "bdd_specs_passing",
      default: false,
      default_details: details(%{reason: "Specs have not gone green on a fresh spex run yet"}),
      except: Enum.map(ready, &ready_story_verdict(&1, profile))
    }
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
end
