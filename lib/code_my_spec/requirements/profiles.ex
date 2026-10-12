defmodule CodeMySpec.Requirements.Profiles do
  @moduledoc """
  One set-based read of a domain slice, shared by every requirement computed
  from it.

  ## Why profiles and not queries-per-handler

  Thirty distinct requirement names, and they do not read thirty different
  things. Five `file_exists` names all read *which roles a component has files
  for*. Three `file_valid` names read *whether those files parsed*. Three issue
  names read *which issues are open and where*. The expensive part is the read,
  the read is shared, and the per-requirement part is a map lookup.

  So a profile is loaded once per drain and every requirement fed by it is
  settled from memory. Adding a requirement is a lookup function; adding a
  profile is a query. Neither is a new query per requirement, which is what a
  handler-per-requirement design quietly becomes.

  Profiles settle fixed requirements across the project. Story-owned issue
  submission nodes are projected with their story family because accepting or
  dismissing an issue changes both membership and edges.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Configurations
  alias CodeMySpec.Deploys.Deploy
  alias CodeMySpec.Epics
  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Issues
  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.{Persona, PersonaStory}
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DevopsSetupChecker
  alias CodeMySpec.Requirements.PersonasChecker
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Stories.AcceptanceCriteria.Criterion
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type name ::
          :issues
          | :files
          | :links
          | :stories
          | :qa
          | :architecture
          | :personas
  @type t :: map()

  @doc """
  Load one profile. Called at most once per drain, however many requirements
  read it.
  """
  @spec load(Scope.t(), name()) :: t()
  def load(%Scope{} = scope, :issues) do
    threshold = Configurations.fix_issues_min_severity(scope)

    %{
      threshold: threshold,
      incoming: Issues.list_triageable(scope, threshold),
      accepted: Issues.list_by_status_and_min_severity(scope, :accepted, threshold),
      incoming_by_story: Issues.incoming_by_story(scope)
    }
  end

  # Every `file_exists` and `file_valid` requirement in the graph — 76 of the
  # 110 definitions — from one file read plus the two entity lists.
  #
  # Eight names, and each maps to exactly one role and one kind across all
  # fifteen graphs: `spec_file`/`spec_valid` to `:spec`, `test_file`/
  # `test_spec_alignment` to `:test`, `review_file`/`review_valid` to `:review`,
  # `implementation_file` to `:implementation`, `bdd_specs_exist` to
  # `:bdd_spec`. So they are a table and two shapes rather than eight handlers.
  #
  # The entity lists are here for the *unsatisfied* side. A component missing a
  # spec needs `expected_path` in its details — `RequirementsFormatter` renders
  # it, and it is the one thing telling an agent where to write the file — and
  # that is per component, so those entities have to be enumerated rather than
  # swept.
  #
  # Files are scoped to the checkout for the reason `Preloader.load/1` gives at
  # length: blended, a file present in another worktree reads as present here,
  # which it measured at 303 components whose specs an agent was told existed
  # and skipped.
  def load(%Scope{active_project_id: project_id} = scope, :files) do
    files =
      Repo.all(
        from(f in FileRecord,
          where: f.project_id == ^project_id,
          # Whole rows, not a chosen subset.
          #
          # Selecting fields looked tidy and silently changed a verdict:
          # `QaIntegrationPlan.check_index/1` reads `size` to decide whether the
          # integrations index is empty, which this did not carry, so every
          # index read as empty and `qa_integration_plan` came back invalid
          # against a project where it is fine. Caught by the diff.
          #
          # A profile feeds checkers written against `Files.File`, and which
          # fields each of them reads is not this module's to know.
          select: f
        )
        |> scope_files_to_copy(scope)
      )

    %{
      project: scope.active_project,
      components: Repo.all(from(c in Component, where: c.project_id == ^project_id)),
      story_ids: Repo.all(from(s in Story, where: s.project_id == ^project_id, select: s.id)),
      by_component_role: index_by(files, :component_id),
      by_story_role: index_by(files, :story_id),
      # For the five project `path_exists` requirements, which ask about named
      # paths rather than about an owner's roles. Same read.
      by_path: Map.new(files, &{&1.path, &1}),
      all: files
    }
  end

  # What each story points at: the component it names, and its UAT deploy.
  #
  # Two requirements, one read each, and both are about a reference rather than
  # about the story — `component_linked` asks whether the named component
  # actually exists, `deploy` whether the recorded deploy passed its health
  # check. Neither is answerable from the story row alone, which is why they are
  # a profile rather than a field lookup.
  def load(%Scope{active_project_id: project_id} = scope, :links) do
    %{
      # What an undeployed story's `deploy` is waiting on, if anything.
      uat_setup_missing: DevopsSetupChecker.missing(scope, "uat"),
      component_id_by_story:
        Repo.all(
          from(s in Story,
            where: s.project_id == ^project_id,
            select: {s.id, s.component_id}
          )
        )
        |> Map.new(),
      component_ids:
        Repo.all(from(c in Component, where: c.project_id == ^project_id, select: c.id))
        |> MapSet.new(),
      # Pinned to UAT because the `deploy` requirement's config is, and
      # `Preloader.uat_deploy_by_story/1` reads it the same way: prod promotion
      # is the release process's business, not this node's.
      uat_deploy_by_story:
        Repo.all(
          from(d in Deploy,
            where: d.project_id == ^project_id and d.environment == "uat"
          )
        )
        |> Map.new(&{&1.story_id, &1})
    }
  end

  # The story rows, and the four collections a story's Three Amigos verdict is
  # read from.
  #
  # One slice, four requirements: `three_amigos_complete` reads the seal and —
  # for the unsealed few — the gap, `story_promoted` reads
  # `promoted_version`, and `stories_exist` and `work_dispatched` are about the
  # set rather than about any row.
  #
  # Every story, not only the released ones. `Shadow.sweep/2` matches on name
  # and entity type and can only touch rows that exist, so the parked stories
  # this carries are swept over harmlessly — and filtering here would mean
  # keeping `Preloader`'s `ready_for_dev` gate in a second place, where it would
  # drift.
  #
  # The four collections are the shape `BddRulesChecker.complete?/3` reads, which
  # is `Preloader`'s: grouped by story id, and empty for a story with none.
  def load(%Scope{active_project_id: project_id} = scope, :stories) do
    stories = Repo.all(from(s in Story, where: s.project_id == ^project_id))
    story_ids = Enum.map(stories, & &1.id)

    %{
      stories: stories,
      # `work_dispatched` asks whether anything is being built. One `exists?`,
      # and the stories above answer the other half — which ready ones belong to
      # no epic — so the checker stops querying for either.
      epic_in_progress?: Epics.in_progress?(scope),
      amigos: %{
        personas_by_story: personas_by_story(story_ids),
        rules_by_story: rules_by_story(project_id),
        criteria_by_story: criteria_by_story(story_ids),
        questions_by_story: questions_by_story(project_id)
      }
    }
  end

  # The newest QA attempt per story, invalidations preloaded — what
  # `QaAttempts.complete?/2` fetches one story at a time.
  #
  # The attempt rather than a boolean, for `Preloader.qa_latest_by_story/1`'s
  # reason: deciding what counts as a pass is the Qa context's judgement, and
  # `status == :pass and invalidations == []` written here would be a second
  # copy of it.
  def load(%Scope{active_project_id: project_id} = scope, :qa) do
    story_ids = Repo.all(from(s in Story, where: s.project_id == ^project_id, select: s.id))

    %{
      submission_snapshots:
        Issues.story_submission_snapshots(
          scope,
          story_ids,
          Configurations.fix_issues_min_severity(scope)
        ),
      latest_by_story:
        Repo.all(
          from(a in QaAttempt,
            where: a.story_id in ^story_ids and not a.stale,
            order_by: [desc_nulls_last: a.review_started_at, desc: a.submitted_at, desc: a.id],
            preload: [:invalidations]
          )
        )
        |> Enum.group_by(& &1.story_id)
        |> Map.new(fn {story_id, [latest | _]} -> {story_id, latest} end)
    }
  end

  # Personas and the files that describe them.
  #
  # Project-wide, not checkout-scoped, and deliberately: a persona describes the
  # project whichever tree its summary was written in — the reason
  # `Files.list_project_files_with_roles/2` exists. `personas_complete` used to
  # issue both of these itself on every drain that touched a file.
  def load(%Scope{} = scope, :personas) do
    %{
      personas: Personas.list_personas(scope),
      files: Files.list_project_files_with_roles(scope, PersonasChecker.persona_roles())
    }
  end

  # Whether the architecture was authored through the tools — half of
  # `architecture_designed`'s "a plan exists".
  def load(%Scope{} = scope, :architecture) do
    %{authored?: Components.any_authored?(scope)}
  end

  # `{owner_id, role} => file`, keeping the first of any duplicates — the same
  # `Enum.find/2` semantics `has_role?/3` and `has_valid_role?/2` use when a
  # checkout somehow holds two rows for one role.
  defp index_by(files, owner_key) do
    files
    |> Enum.filter(&Map.get(&1, owner_key))
    |> Enum.reduce(%{}, fn file, acc ->
      Map.put_new(acc, {Map.get(file, owner_key), file.role}, file)
    end)
  end

  # `Preloader.files_vantage/1` decides, including for a reader that named no
  # checkout — which resolves to the project's main copy rather than blending.
  #
  # This blended, and the diff caught it: on the unscoped vantage twenty
  # components read as having an implementation that exists only in another
  # worktree, `handlers.ex` and `profiles.ex` among them. Over-satisfaction is
  # the expensive direction — an agent is told the work is done and skips it —
  # and it is the whole reason that function exists.
  defp scope_files_to_copy(query, %Scope{active_working_copy_id: copy} = scope) do
    case copy || Preloader.files_vantage(scope) do
      nil -> query
      vantage -> from(f in query, where: f.working_copy_id == type(^vantage, Ecto.UUID))
    end
  end

  # `Preloader`'s four, in its shapes — rules and questions carry a project id,
  # criteria and personas are reachable only through their story.
  defp rules_by_story(project_id) do
    Repo.all(from(r in Rule, where: r.project_id == ^project_id and not is_nil(r.story_id)))
    |> Enum.group_by(& &1.story_id)
  end

  defp questions_by_story(project_id) do
    Repo.all(from(q in Question, where: q.project_id == ^project_id and not is_nil(q.story_id)))
    |> Enum.group_by(& &1.story_id)
  end

  # Ordered as `AcceptanceCriteria.list_story_criteria/2` orders them, because
  # `bdd_specs_exist` reports `missing_criteria` and a list in a different
  # order is a different answer — the diff compares details, and two rows that
  # agree on the verdict while disagreeing on the list are a difference somebody
  # investigates later for nothing.
  defp criteria_by_story(story_ids) do
    Repo.all(
      from(c in Criterion,
        where: c.story_id in ^story_ids and is_nil(c.retired_at),
        order_by: [asc: c.inserted_at, asc: c.id]
      )
    )
    |> Enum.group_by(& &1.story_id)
  end

  defp personas_by_story(story_ids) do
    Repo.all(
      from(ps in PersonaStory,
        join: p in Persona,
        on: p.id == ps.persona_id,
        where: ps.story_id in ^story_ids,
        select: {ps.story_id, p}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end
end
