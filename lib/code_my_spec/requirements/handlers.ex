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
    "issue_updated" => [:issues]
  }

  # Which requirements each profile settles. Adding a requirement to a profile
  # already loaded costs nothing at read time.
  @fed_by %{
    issues: ["issues_triaged", "issues_resolved", "story_issues_resolved"]
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
