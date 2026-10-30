defmodule CodeMySpec.Requirements.Profiles do
  @moduledoc """
  One set-based read of a domain slice, shared by every requirement computed
  from it.

  Many requirements read the same slice (which roles a component has files
  for, which issues are open), so a profile is loaded once per drain and every
  requirement it feeds is settled from memory. Adding a requirement is a lookup;
  adding a profile is a query.

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
  alias CodeMySpec.Issues
  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.{Persona, PersonaStory}
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DevopsSetupChecker
  alias CodeMySpec.Requirements.PersonasChecker
  alias CodeMySpec.Stories.AcceptanceCriteria.Criterion
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type name ::
          :dispatch
          | :issues
          | :links
          | :stories
          | :qa
          | :architecture
          | :personas
  @type t :: map()

  @shared [:stories, :links, :qa, :personas, :architecture]
  @cache {__MODULE__, :drain}

  @doc """
  Load one profile. Called at most once per drain, however many requirements
  read it: within `once_per_drain/1` a profile no checkout changes is loaded
  once for every vantage the drain settles.
  """
  @spec load(Scope.t(), name()) :: t()
  def load(scope, name) when name in @shared do
    case Process.get(@cache) do
      nil ->
        fetch(scope, name)

      cache ->
        profile = Map.get_lazy(cache, name, fn -> fetch(scope, name) end)
        Process.put(@cache, Map.put(cache, name, profile))
        profile
    end
  end

  def load(scope, name), do: fetch(scope, name)

  @doc """
  Run `fun` with each profile that reads no checkout's files loaded at most once.

  `:issues` leaves out issues on stories placed at another checkout, so it
  loads for each scope; the rest read only records.
  """
  @spec once_per_drain((-> result)) :: result when result: term()
  def once_per_drain(fun) do
    Process.put(@cache, %{})

    try do
      fun.()
    after
      Process.delete(@cache)
    end
  end

  defp fetch(%Scope{} = scope, :issues) do
    threshold = Configurations.fix_issues_min_severity(scope)

    %{
      threshold: threshold,
      incoming: Issues.list_triageable(scope, threshold),
      accepted: Issues.list_by_status_and_min_severity(scope, :accepted, threshold),
      incoming_by_story: Issues.incoming_by_story(scope)
    }
  end

  # What `work_dispatched` reads of `:stories`, without the Three Amigos
  # collections it does not.
  defp fetch(%Scope{active_project_id: project_id} = scope, :dispatch) do
    %{
      stories: Repo.all(from(s in Story, where: s.project_id == ^project_id)),
      epic_in_progress?: Epics.in_progress?(scope)
    }
  end

  # What each story points at: the component it names, and its UAT deploy.
  #
  # `component_linked` asks whether the named component exists, `deploy`
  # whether the recorded deploy passed its health check; neither is answerable
  # from the story row alone.
  defp fetch(%Scope{active_project_id: project_id} = scope, :links) do
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
      # UAT only, as the `deploy` requirement and `Preloader` read it.
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
  # Every story, not only ready ones: a sweep touches only rows that exist, so
  # parked stories are harmless, and filtering would copy `Preloader`'s gate.
  # The collections are in `Preloader`'s shape, which `BddRulesChecker` reads.
  defp fetch(%Scope{active_project_id: project_id} = scope, :stories) do
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
  # `QaAttempts.complete?/2` fetches one story at a time. The attempt, not a
  # boolean: what counts as a pass is the Qa context's judgement.
  defp fetch(%Scope{active_project_id: project_id} = scope, :qa) do
    story_ids = Repo.all(from(s in Story, where: s.project_id == ^project_id, select: s.id))
    threshold = Configurations.fix_issues_min_severity(scope)

    latest_by_story =
      Repo.all(
        from(a in QaAttempt,
          where: a.story_id in ^story_ids and not a.stale,
          order_by: [desc_nulls_last: a.review_started_at, desc: a.submitted_at, desc: a.id],
          preload: [:invalidations]
        )
      )
      |> Enum.group_by(& &1.story_id)
      |> Map.new(fn {story_id, [latest | _]} -> {story_id, latest} end)

    # A partial/fail attempt may cite issues on another story. Read those
    # issues once for the whole profile instead of resolving every cited ID
    # separately while settling each story.
    issues_by_id =
      if Enum.any?(latest_by_story, fn {_id, attempt} ->
           attempt.status in [:partial, :fail] and attempt.invalidations == []
         end) do
        Map.new(Issues.list_issues(scope), &{&1.id, &1})
      else
        %{}
      end

    %{
      submission_snapshots: Issues.story_submission_snapshots(scope, story_ids, threshold),
      latest_by_story: latest_by_story,
      issues_by_id: issues_by_id,
      issue_threshold: threshold
    }
  end

  # Personas and the files that describe them.
  #
  # Project-wide, not checkout-scoped: a persona describes the project whichever
  # tree its summary was written in.
  defp fetch(%Scope{} = scope, :personas) do
    %{
      personas: Personas.list_personas(scope),
      files: Files.list_project_files_with_roles(scope, PersonasChecker.persona_roles())
    }
  end

  # Whether the architecture was authored through the tools — half of
  # `architecture_designed`'s "a plan exists" — and what a proposal may name.
  defp fetch(%Scope{active_project_id: project_id} = scope, :architecture) do
    # `Stories.list_project_stories/1`'s stories (live ones), numbers only.
    numbers =
      Repo.all(
        from(s in Story,
          where: s.project_id == ^project_id and is_nil(s.retired_at),
          select: s.number
        )
      )

    %{
      authored?: Components.any_authored?(scope),
      story_numbers: numbers,
      context_names: scope |> Components.list_contexts() |> Enum.map(& &1.module_name)
    }
  end

  @doc """
  The `:files` profile from one checkout's files and the project's records, read
  from nothing: a harness builds it from its own scan.
  """
  @spec files_profile([map()], map() | nil, [map()], [integer()]) :: t()
  def files_profile(files, project, components, story_ids) do
    %{
      project: project,
      components: components,
      story_ids: story_ids,
      by_component_role: index_by(files, :component_id),
      by_story_role: index_by(files, :story_id),
      # For the project `path_exists` requirements, which ask about named
      # paths rather than an owner's roles. Same read.
      by_path: Map.new(files, &{&1.path, &1}),
      all: files
    }
  end

  @doc "The project's live criteria by story, as `:stories` holds them."
  @spec criteria(Scope.t()) :: %{integer() => [map()]}
  def criteria(%Scope{active_project_id: project_id}) do
    Repo.all(from(s in Story, where: s.project_id == ^project_id, select: s.id))
    |> criteria_by_story()
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

  # Ordered as `AcceptanceCriteria.list_story_criteria/2` orders them:
  # `bdd_specs_exist` reports `missing_criteria`, and another order is another
  # answer.
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
