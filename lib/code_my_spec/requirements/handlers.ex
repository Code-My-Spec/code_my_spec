defmodule CodeMySpec.Requirements.Handlers do
  @moduledoc """
  Domain events applied to the projection, without re-deriving anything.

  ## The distinction this module exists to make

  An invalidation says *an entity moved*, and the only way to answer one is to
  recompute that entity — every requirement it has, every checker, against the
  database. An event says *what happened*, and a handler settles the
  requirements that event can move and nothing else.

  Measured on this project before any of this existed: one incoming issue ran
  **22 checkers** — all fourteen project requirements and all eight of a story's
  — to settle the one it could possibly have moved. 238ms.

  ## A handler owns a requirement, not an entity

  The second thing this is not: a per-entity recheck. Asking "what does this
  event do to story 799" and then "to story 800" is entity-thinking with extra
  steps, and it scales with the number of stories.

  A handler owns a *requirement name across the whole project* and settles it
  set-wise. `story_issues_resolved` is one grouped query — every story carrying
  an unresolved issue — and two writes: satisfied for all of them, then
  unsatisfied for the few the query named. Thirty-eight stories or three
  thousand, it is the same three queries.

  So the issue surface costs:

      issues_triaged          1 query   (incoming at or above threshold)
      issues_resolved         1 query   (accepted at or above threshold)
      story_issues_resolved   1 query   (accepted, grouped by story)

  Three queries and four writes for every issue node in the project, against
  22 checkers for one of them.

  ## Each requirement keeps its own filters

  The three do not share a filter set and must not be collapsed into one query.
  `issues_triaged` and `issues_resolved` read through
  `list_by_status_and_min_severity/3`, which applies
  `exclude_framework_unless_vendor/2` and `exclude_other_copies_stories/2`.
  `story_issues_resolved` reads through `list_by_story_status_and_min_severity/4`,
  which applies neither — so on a non-vendor project a framework issue counts
  against a story and not against the project.

  That asymmetry may be a defect; it is not this module's to fix. Handlers call
  the same functions the checkers call, so whatever the requirement means today,
  the handler means it too.

  ## No handler is a valid answer

  `:no_handler` means nothing here knows about this event, and the caller falls
  back to invalidating and recomputing — correct, and slow. That is what lets
  handlers arrive one requirement at a time rather than all at once, and the
  shadow diff scores either path identically.

  `{:ok, []}` is a different answer: the event happened and moved nothing the
  graph reads. Collapsing the two would let an uninteresting event silently skip
  work it owed.
  """

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
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
  A requirement settled across every entity at once.

  `default` is what the requirement is for entities the query did not name, and
  `except` is the handful it did. The satisfied direction is the default here —
  a story with no unresolved issue is resolved — which is what makes one query
  settle a whole population rather than only the exceptions.
  """
  @type sweep :: %{
          entity_type: String.t(),
          name: String.t(),
          default: boolean(),
          default_details: map(),
          except: [change()]
        }

  @issue_kinds ~w(issue_created issue_accepted issue_dismissed issue_resolved issue_updated)

  @doc """
  What this event does to the projection.

  Answers `{:ok, changes, sweeps}` — individual rows to set, and requirements to
  settle across a whole population.
  """
  @spec apply_event(Scope.t(), String.t(), map()) ::
          {:ok, [change()], [sweep()]} | :no_handler
  def apply_event(scope, kind, payload)

  def apply_event(%Scope{} = scope, kind, _payload) when kind in @issue_kinds do
    threshold = Configurations.fix_issues_min_severity(scope)
    project_id = scope.active_project.id

    incoming = Issues.list_by_status_and_min_severity(scope, :incoming, threshold)
    accepted = Issues.list_by_status_and_min_severity(scope, :accepted, threshold)
    by_story = Issues.unresolved_by_story(scope, threshold)

    changes = [
      project_verdict(project_id, "issues_triaged", incoming, "untriaged", threshold),
      project_verdict(project_id, "issues_resolved", accepted, "unresolved", threshold)
    ]

    {:ok, changes, [story_issues_sweep(by_story, threshold)]}
  end

  def apply_event(_scope, _kind, _payload), do: :no_handler

  # -- Issues --

  # The same shape `IssuesChecker.triaged?/2` and `resolved?/2` return, because
  # a row this settles has to read the same as one a recompute settled — the
  # diff compares verdicts, and a verdict that agreed while explaining itself
  # differently is a difference somebody investigates later for nothing.
  defp project_verdict(project_id, name, [], _word, threshold),
    do:
      change("project", project_id, name, true, %{
        status: "No #{status_word(name)} issues at #{threshold}+ severity"
      })

  defp project_verdict(project_id, name, issues, word, threshold),
    do:
      change("project", project_id, name, false, %{
        reason: "#{length(issues)} #{word} #{threshold}+ issues"
      })

  defp status_word("issues_triaged"), do: "untriaged"
  defp status_word("issues_resolved"), do: "unresolved"

  # One query settles every story: those the grouping named are unsatisfied,
  # and every other story in the projection is satisfied by virtue of absence.
  defp story_issues_sweep(by_story, threshold) do
    %{
      entity_type: "story",
      name: "story_issues_resolved",
      default: true,
      default_details:
        Requirement.normalize_details(%{
          status: "No unresolved #{threshold}+ issues on this story"
        }),
      except:
        Enum.map(by_story, fn {story_id, issues} ->
          change("story", story_id, "story_issues_resolved", false, %{
            reason: "#{length(issues)} unresolved #{threshold}+ issue(s) on this story",
            issues: Enum.map(issues, &"#{&1.severity}: #{&1.title}")
          })
        end)
    }
  end

  defp change(entity_type, entity_id, name, satisfied, details),
    do: %{
      entity_type: entity_type,
      entity_id: entity_id,
      name: name,
      satisfied: satisfied,
      details: Requirement.normalize_details(details)
    }
end
