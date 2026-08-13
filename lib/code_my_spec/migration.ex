defmodule CodeMySpec.Migration do
  @moduledoc """
  Copies a project's authored records from a local harness onto the cloud.

  Story 991. What travels is what Sam wrote: stories, rules, scenarios,
  personas, epics, issues, questions and the project's configuration. What does
  not travel is everything the harness can recompute — files, problems,
  sessions, components, requirements. Those are ~5,000 of the ~6,500 rows a
  local project holds, and the cloud rebuilds them from the working copy on
  first sync.

  One call, one transaction. A migration that half-lands is worse than one that
  fails: Sam would have to work out what arrived before he could retry, and the
  story forbids leaving him that job.

  ## Remapping

  The hard part, and the reason this is not a database copy. Local ids mean
  nothing here — stories are integers assigned by a SQLite sequence, and the
  cloud assigns its own. Every reference is rewritten as the graph lands, which
  is why insert order is fixed rather than incidental: a criterion cannot be
  written until both the story and the rule it points at have real ids.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.{
    AcceptanceCriteria,
    BddRules,
    Epics,
    Issues,
    Personas,
    Questions,
    Repo,
    Stories
  }

  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.QaAttempts
  alias CodeMySpec.Users.Scope

  @derived ~w(files problems sessions components requirements analysis_runs file_edits)

  @doc "Kinds the harness recomputes, which this deliberately does not carry."
  @spec derived_kinds() :: [String.t()]
  def derived_kinds, do: @derived

  @doc """
  Read one project's authored graph off the local harness.

  Reads through the contexts rather than the database, because the local
  harness runs this same code over SQLite — so there is no second set of
  queries to keep in step with the schema, and no raw SQL to drift.

  Local ids travel as `local_id` and are the only thing tying the payload
  together. The cloud assigns its own and rewrites every reference as it lands.

  Reads nothing and writes nothing outside this project: story 991 says
  migrating one project leaves Sam's others alone, and the surest way to keep
  that true is to never look at them.
  """
  @spec export_project(Scope.t()) :: map()
  def export_project(%Scope{} = scope) do
    stories = list_stories(scope)
    personas = Personas.list_personas(scope)

    %{
      "stories" => Enum.map(stories, &export_story/1),
      "epics" => Enum.map(Epics.list_epics(scope), &export_epic/1),
      "personas" => Enum.map(personas, &export_persona/1),
      "persona_stories" => export_persona_links(scope, stories),
      "rules" => Enum.flat_map(stories, &export_rules(scope, &1)),
      "criteria" => Enum.flat_map(stories, &export_criteria(scope, &1)),
      # The moduledoc has always said these travel. They did not — export_project
      # built six collections and stopped, so a migrated project arrived with no
      # issue history, no open questions and no QA record at all.
      "issues" => export_issues(scope),
      "questions" => Enum.flat_map(stories, &export_questions(scope, &1)),
      "qa_attempts" => Enum.flat_map(stories, &export_qa_attempts(scope, &1))
    }
  end

  # One walk per export, keyed by the criterion id embedded in each filename.
  # Memoised in the process dictionary: 921 criteria each globbing the tree is
  # 921 walks of the same directory.
  #
  # Only the harness has a disk. On a server this finds nothing and every
  # criterion falls back to whatever it already recorded, which is correct —
  # the server does not hold spex files, it holds what the harness said about
  # them.
  defp spex_files(scope) do
    case Process.get(:cms_migration_spex_files) do
      nil ->
        found = scan_spex_files(scope)
        Process.put(:cms_migration_spex_files, found)
        found

      found ->
        found
    end
  end

  defp scan_spex_files(%Scope{active_project: %{local_path: root}}) when is_binary(root) do
    [root, "test", "spex", "**", "criterion_*_spex.exs"]
    |> Path.join()
    |> Path.wildcard()
    |> Map.new(fn path -> {criterion_id_from(path), Path.relative_to(path, root)} end)
  end

  defp scan_spex_files(_scope), do: %{}

  # "criterion_8209_an_anonymous_visitor_..._spex.exs" -> "8209"
  defp criterion_id_from(path) do
    path
    |> Path.basename()
    |> String.split("_")
    |> Enum.at(1)
  end

  defp export_scenarios(nil), do: []

  defp export_scenarios(scenarios) do
    Enum.map(scenarios, fn scenario ->
      %{
        "name" => scenario.name,
        "status" => scenario.status && to_string(scenario.status),
        "observation" => scenario.observation
      }
    end)
  end

  defp export_issues(scope) do
    scope
    |> Issues.list_issues()
    |> Enum.map(
      &%{
        "local_id" => &1.id,
        # Integer story ids, remapped like every other reference.
        "story_local_id" => &1.story_id,
        "title" => &1.title,
        "description" => &1.description,
        "severity" => &1.severity && to_string(&1.severity),
        "scope" => &1.scope && to_string(&1.scope),
        "status" => &1.status && to_string(&1.status),
        "category" => &1.category && to_string(&1.category),
        "resolution" => &1.resolution,
        "source" => &1.source,
        "source_path" => &1.source_path,
        "attachments" => &1.attachments
      }
    )
  end

  defp export_questions(scope, story) do
    scope
    |> Questions.list_questions_for_story(story.id)
    |> Enum.map(
      &%{
        "local_id" => &1.id,
        "story_local_id" => story.id,
        "text" => &1.text,
        "status" => &1.status && to_string(&1.status)
      }
    )
  end

  # Ordered oldest first so a parent attempt is always written before the
  # attempt that supersedes it — `parent_attempt_id` is a self-reference and
  # cannot be rewritten against a row that does not exist yet.
  defp export_qa_attempts(scope, story) do
    scope
    |> QaAttempts.list(story.id)
    |> Enum.sort_by(& &1.submitted_at, DateTime)
    |> Enum.map(
      &%{
        "local_id" => &1.id,
        "story_local_id" => story.id,
        "status" => &1.status && to_string(&1.status),
        # Embedded structs, flattened to plain maps: an embed is not
        # JSON-encodable, and the payload has to survive a round trip through
        # the wire before the destination casts it back.
        "scenarios" => export_scenarios(&1.scenarios),
        "issue_local_ids" => &1.issue_ids || [],
        "parent_local_id" => &1.parent_attempt_id,
        "agent_id" => &1.agent_id,
        "task_id" => &1.task_id,
        "submitted_at" => &1.submitted_at
      }
    )
  end

  defp export_story(story),
    do: %{
      "local_id" => story.id,
      "title" => story.title,
      "story" => story.story,
      "description" => story.description,
      # Authored state, all of it. Carrying only title/story/description
      # left every migrated story parked: `ready_for_dev` is what releases a
      # story into the requirement graph, so a project arrived with 91 stories
      # marked ready at the source and 0 here, and the graph saw almost nothing
      # to work on. `notes`, `priority` and `specs_ready` were dropped the same
      # way — 26, 52 and 8 stories' worth.
      "ready_for_dev" => story.ready_for_dev,
      "specs_ready" => story.specs_ready,
      "notes" => story.notes,
      "priority" => story.priority,
      # The importer has always read this to rewire the epic; nothing ever
      # wrote it, so all 16 epic memberships were silently dropped while the
      # epics themselves migrated.
      "epic_local_id" => story.epic_id,
      # By module name, not id. Components are projections of files — each
      # deployment derives its own from the same source, so the ids differ and
      # the module name is what both sides agree on. It is the natural key
      # `components_module_name_project_id_index` already enforces.
      #
      # Without this the link is simply dropped, and requirements are computed
      # per story and component: a migrated project reports 0/0 satisfied for
      # everything, which reads as "nothing is done" rather than "nothing is
      # linked".
      "component_module_name" => story.component && story.component.module_name
    }

  defp export_epic(epic),
    do: %{
      "local_id" => epic.id,
      "name" => epic.name,
      # Carried because they are authored. Only the name travelled before, so
      # an epic arrived with its description gone and a slug the destination
      # re-derived from the name — which is a different string whenever Sam
      # edited one without the other.
      "slug" => epic.slug,
      "description" => epic.description
    }

  defp export_persona(persona),
    do: %{
      "local_id" => persona.id,
      "name" => persona.name,
      "slug" => persona.slug,
      # The headline is the persona in one line, and it was dropped. So was the
      # type, which decides whether a persona is a proto sketch or researched —
      # a distinction the product surfaces treat differently.
      "headline" => persona.headline,
      "persona_type" => persona.persona_type && to_string(persona.persona_type)
    }

  defp export_persona_links(scope, stories) do
    Enum.flat_map(stories, fn story ->
      scope
      |> Personas.list_personas_for_story(story.id)
      |> Enum.map(&%{"persona_local_id" => &1.id, "story_local_id" => story.id})
    end)
  end

  defp export_rules(scope, story) do
    scope
    |> BddRules.list_rules_for_story(story.id)
    |> Enum.map(
      &%{"local_id" => &1.id, "story_local_id" => story.id, "statement" => &1.statement}
    )
  end

  defp export_criteria(scope, story) do
    spex = spex_files(scope)

    scope
    |> AcceptanceCriteria.list_story_criteria(story.id)
    |> Enum.map(
      &%{
        "local_id" => &1.id,
        "story_local_id" => story.id,
        "rule_local_id" => &1.rule_id,
        "description" => &1.description,
        "body" => &1.body,
        # Read off disk rather than derived. The derived path was pinned to the
        # criterion's id and a slug of its description, and both move: the id on
        # migration — which renumbers every story, so all 86 directories name
        # something else — and the slug whenever somebody edits the words.
        #
        # Taking the real filename means the destination records where the file
        # actually is, and a re-run brings it across unchanged.
        "spec_path" => &1.spec_path || Map.get(spex, to_string(&1.id)),
        # 912 of 921 criteria in this project carry a kind, and none of them
        # arrived with one. It separates the happy path from the failure path,
        # which is the whole shape of a scenario set — a migrated project looked
        # like it had 921 undifferentiated criteria.
        "kind" => &1.kind && to_string(&1.kind),
        # QA state. Nothing is verified in this project today, so this has cost
        # nothing yet; it would have, silently, the first time it mattered.
        "verified" => &1.verified,
        "verified_at" => &1.verified_at
      }
    )
  end

  defp list_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> Repo.preload(stories, :component)
      stories when is_list(stories) -> Repo.preload(stories, :component)
      _ -> []
    end
  end

  @doc """
  Import one project's authored graph.

  Returns `{:ok, summary}` where summary counts what arrived per kind, or
  `{:error, reason}` having written nothing.
  """
  @spec import_project(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def import_project(%Scope{} = scope, payload) when is_map(payload) do
    case plan(scope) do
      :paid -> do_import(scope, payload)
      _ -> {:error, :plan_required}
    end
  end

  # Checked before the transaction opens rather than inside it. Sam is told a
  # plan is what is missing, not that something went wrong, and nothing is
  # written on the way to finding out.
  #
  # Read from the account rather than from the scope's association: a scope
  # built from an access token carries `active_account_id` and no loaded
  # struct, so trusting the association reported "no plan" for an account that
  # had one. Every spec set it explicitly and none of them caught it — the
  # first real request did.
  defp plan(%Scope{active_account: %{plan: plan}}) when not is_nil(plan), do: plan

  defp plan(%Scope{active_account_id: id}) when not is_nil(id) do
    case Repo.get(CodeMySpec.Accounts.Account, id) do
      %{plan: plan} -> plan
      nil -> nil
    end
  end

  defp plan(_scope), do: nil

  defp do_import(scope, payload) do
    Repo.transaction(fn ->
      with {:ok, graph} <- put_graph(scope, payload),
           {:ok, records} <- put_records(scope, payload, graph) do
        summarise(graph, records)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # What Sam authored, in the order the references demand.
  #
  # Personas and their links come before criteria, not after. A criterion
  # cannot be created for a story with no linked persona — the harness refuses
  # with :persona_linkage_required, because a scenario without a persona has no
  # voice. Rules need stories, criteria need rules AND a persona-linked story,
  # and stories need their epic.
  defp put_graph(scope, payload) do
    with {:ok, epics} <- put_epics(scope, payload["epics"] || []),
         {:ok, stories} <- put_stories(scope, payload["stories"] || [], epics),
         {:ok, personas} <- put_personas(scope, payload["personas"] || []),
         :ok <- link_personas(scope, payload["persona_stories"] || [], stories, personas),
         {:ok, rules} <- put_rules(scope, payload["rules"] || [], stories),
         {:ok, criteria} <- put_criteria(scope, payload["criteria"] || [], stories, rules) do
      {:ok,
       %{epics: epics, stories: stories, personas: personas, rules: rules, criteria: criteria}}
    end
  end

  # What happened to it since: issues raised, questions asked, QA run.
  #
  # All of it hangs off a story, so it follows the graph. Issues come before
  # attempts because an attempt names the issues it raised.
  defp put_records(scope, payload, %{stories: stories}) do
    with {:ok, issues} <- put_issues(scope, payload["issues"] || [], stories),
         {:ok, questions} <- put_questions(scope, payload["questions"] || [], stories),
         {:ok, attempts} <- put_attempts(scope, payload["qa_attempts"] || [], stories, issues) do
      {:ok, %{issues: issues, questions: questions, qa_attempts: attempts}}
    end
  end

  defp summarise(graph, records) do
    graph
    |> Map.merge(records)
    |> Map.new(fn {kind, created} -> {kind, map_size(created)} end)
    |> Map.put(:skipped, @derived)
  end

  # Each of these returns a map of local_id => the record the cloud created, and
  # every later step reads references out of those maps rather than out of the
  # payload. That is the remapping, and keeping it in one shape per kind is what
  # stops it leaking into the individual inserts.

  # Epics are unique on (project_id, name), so a second run collides unless it
  # recognises what it wrote the first time. This was the last thing standing
  # between the real dataset and a repeatable migration — the spex covered
  # re-running stories, rules, criteria and personas, and never an epic.
  defp put_epics(scope, epics) do
    existing = Epics.list_epics(scope)

    collect(epics, fn epic ->
      case Enum.find(existing, &(&1.name == epic["name"])) do
        %{} = already ->
          resync(already, epic, [:slug, :description], &Epics.update_epic(scope, &1, &2))

        nil ->
          Epics.create_epic(scope, attrs(epic, Epics.Epic))
      end
    end)
  end

  defp put_stories(scope, stories, epics) do
    known = scope |> project_stories() |> index_stories()
    components = component_ids_by_module(scope)

    stories
    |> Enum.reduce_while({:ok, %{}, %{}}, fn story, {:ok, acc, made} ->
      case put_story(scope, story, known, made, components, epics) do
        {:ok, created} ->
          {:cont,
           {:ok, Map.put(acc, story["local_id"], created),
            Map.put(made, story["title"], {story["local_id"], created})}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc, _made} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  # `known` is the destination as it was *before* this run, and is not updated
  # as rows are created — so a title this run has already inserted is invisible
  # to every later story, and the second one inserts again and dies on
  # `stories_title_project_id_index`. That surfaced as a 500 from
  # `POST /api/migrations` importing 98 stories into an empty project, with
  # nothing in the message naming the title or either source story.
  #
  # `made` closes that. What it does about a collision depends on which one it
  # is, because the two want opposite handling:
  #
  #   - the same source story twice in one payload is a duplicate entry, and
  #     the right answer is the row already created for it
  #   - two *different* source stories sharing a title cannot both exist under
  #     a unique index, and no import can decide which of Sam's stories to
  #     keep. Adopting one for the other is the silent merge `match_by_title`
  #     already refuses; this says so instead, naming both.
  defp put_story(scope, story, known, made, components, epics) do
    case Map.get(made, story["title"]) do
      nil -> create_or_relink(scope, story, known, components, epics)
      {local_id, created} -> adopt_or_conflict(local_id, created, story)
    end
  end

  defp adopt_or_conflict(local_id, created, %{"local_id" => local_id}), do: {:ok, created}

  defp adopt_or_conflict(local_id, _created, story) do
    {:error, {:duplicate_title, story["title"], local_id, story["local_id"]}}
  end

  defp create_or_relink(scope, story, known, components, epics) do
    case find_existing(known, story) do
      %{} = already ->
        relink(scope, already, components, epics, story)

      nil ->
        story
        |> attrs(Stories.Story)
        |> put_ref(:epic_id, epics[story["epic_local_id"]])
        |> put_component(components, story["component_module_name"])
        |> Map.put(:migrated_from_id, story["local_id"])
        |> then(&Stories.create_story(scope, &1))
    end
  end

  # A story that is already here still takes its authored state from the
  # payload: the component it is mapped to, and the flags that decide what the
  # graph does with it.
  #
  # Recognising a row and returning it untouched made "idempotent" mean
  # "inert": a correction upstream carried nothing, so every one needed a
  # hand-written backfill against the destination. That is how nine stories
  # came to point at components that no longer existed, and how 91 stories
  # stayed parked after `ready_for_dev` started being exported — the first run
  # created them without it, and no later run could put it right.
  #
  # Title, narrative and description are deliberately not re-applied. Those are
  # edited at the destination once a project has moved, and the source stops
  # being authoritative about them the moment somebody does. Readiness and
  # priority are the migration's business until the move is finished.
  defp relink(scope, story, components, epics, payload) do
    story
    |> resync_attrs(components, epics, payload)
    |> case do
      changes when map_size(changes) == 0 -> {:ok, story}
      changes -> Stories.update_story(scope, story, changes)
    end
  end

  # The same rule the story reuse path follows, for the entities whose reuse is
  # a plain find: a row that is already here still takes the payload's authored
  # values. Without it, a field added to the export after a project has moved
  # can never reach the rows migrated before it — 912 criteria sat without a
  # kind for exactly that reason.
  defp resync(record, payload, keys, update) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      put_changed(acc, record, key, payload[to_string(key)])
    end)
    |> case do
      changes when map_size(changes) == 0 -> {:ok, record}
      changes -> update.(record, changes)
    end
  end

  defp resync_attrs(story, components, epics, payload) do
    epic = epics[payload["epic_local_id"]]

    %{}
    |> put_changed(
      story,
      :component_id,
      Map.get(components, payload["component_module_name"] || :none)
    )
    |> put_changed(story, :epic_id, epic && epic.id)
    |> put_changed(story, :ready_for_dev, payload["ready_for_dev"])
    |> put_changed(story, :specs_ready, payload["specs_ready"])
    |> put_changed(story, :priority, payload["priority"])
    |> put_changed(story, :notes, payload["notes"])
  end

  # Only what actually differs, so a re-run with nothing to say writes nothing
  # and `updated_at` stays honest about when a story last changed.
  defp put_changed(changes, _story, _key, nil), do: changes

  defp put_changed(changes, story, key, value) do
    if Map.get(story, key) == value, do: changes, else: Map.put(changes, key, value)
  end

  # Two indexes because a second run has two ways to recognise its own work, and
  # they are not equally good. `migrated_from_id` is the source's own id, which
  # nothing here edits; title is a string a human rewrites. Before the id was
  # recorded, retitling a story upstream made it a second story here on the next
  # run, and two stories sharing a title collapsed into one.
  #
  # Title is still consulted, for rows written before the id existed. It is the
  # fallback rather than the key.
  defp index_stories(stories) do
    %{
      by_source:
        Map.new(Enum.reject(stories, &is_nil(&1.migrated_from_id)), &{&1.migrated_from_id, &1}),
      by_title: Map.new(stories, &{&1.title, &1})
    }
  end

  defp find_existing(%{by_source: by_source, by_title: by_title}, story) do
    case Map.get(by_source, story["local_id"]) do
      %{} = matched -> matched
      nil -> match_by_title(Map.get(by_title, story["title"]), story)
    end
  end

  # Title only decides for a row that cannot say where it came from. A row that
  # already names a *different* source story is a different story that happens
  # to share a title, and treating it as this one merges two of Sam's stories
  # into whichever arrived first — silently, since the importer then reports it
  # as migrated.
  #
  # Returning nil sends it to the insert, where the destination's unique title
  # index refuses it and the whole import rolls back. Loud and recoverable beats
  # quiet and lossy.
  defp match_by_title(nil, _story), do: nil

  defp match_by_title(%{migrated_from_id: nil} = candidate, _story), do: candidate

  defp match_by_title(%{migrated_from_id: source_id} = candidate, story) do
    if source_id == story["local_id"], do: candidate, else: nil
  end

  # A component this deployment does not have yet is left unlinked rather than
  # invented. Components are synced from files, so the missing one either
  # arrives with the next scan — and the story can be linked then — or it never
  # existed here, and a component conjured from a name would be a fiction the
  # requirement graph would then compute against.
  defp put_component(attrs, _components, nil), do: attrs

  defp put_component(attrs, components, module_name),
    do: put_component_id(attrs, Map.get(components, module_name))

  defp put_component_id(attrs, nil), do: attrs
  defp put_component_id(attrs, id), do: Map.put(attrs, :component_id, id)

  defp component_ids_by_module(%Scope{active_project_id: project_id}) do
    CodeMySpec.Components.Component
    |> where([c], c.project_id == ^project_id)
    |> select([c], {c.module_name, c.id})
    |> Repo.all()
    |> Map.new()
  end

  # Idempotence by natural key rather than by remembering local ids. Migrating
  # twice must not produce two of anything, and the second run has no memory of
  # the first — so the question it can answer is "is this story already here",
  # not "did I write this before". A title within a project is the identity Sam
  # would use himself.
  defp project_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
      _ -> []
    end
  end

  # Matched on title within a story. Issues carry no id the destination could
  # recognise, and a second run must not file every issue again.
  defp put_issues(scope, issues, stories) do
    existing = scope |> Issues.list_issues() |> Map.new(&{{&1.story_id, &1.title}, &1})

    collect(issues, fn issue ->
      story = stories[issue["story_local_id"]]

      case Map.get(existing, {story && story.id, issue["title"]}) do
        %{} = already ->
          {:ok, already}

        nil ->
          issue
          |> attrs(Issues.Issue)
          |> Map.put(:story_id, story && story.id)
          |> then(&Issues.create_issue(scope, &1))
      end
    end)
  end

  # Matched on text within a story, for the same reason.
  defp put_questions(scope, questions, stories) do
    collect(questions, fn question ->
      case stories[question["story_local_id"]] do
        nil -> {:error, {:unknown_story, question["story_local_id"]}}
        story -> upsert_question(scope, story, question)
      end
    end)
  end

  defp upsert_question(scope, story, question) do
    scope
    |> Questions.list_questions_for_story(story.id)
    |> Enum.find(&(&1.text == question["text"]))
    |> case do
      %{} = already -> {:ok, already}
      nil -> Questions.create_question(scope, story.id, attrs(question, Questions.Question))
    end
  end

  # Matched on `submitted_at` within a story: microsecond precision, and an
  # attempt is a point-in-time event rather than something edited.
  #
  # `issue_ids` are rewritten against what this run created — an attempt naming
  # an issue by the harness's id would point at nothing here, or worse, at some
  # other project's row.
  defp put_attempts(scope, attempts, stories, issues) do
    collect(attempts, fn attempt ->
      case stories[attempt["story_local_id"]] do
        nil -> {:error, {:unknown_story, attempt["story_local_id"]}}
        story -> upsert_attempt(scope, story, attempt, issues)
      end
    end)
  end

  defp upsert_attempt(scope, story, attempt, issues) do
    scope
    |> QaAttempts.list(story.id)
    |> Enum.find(&same_instant?(&1.submitted_at, attempt["submitted_at"]))
    |> case do
      %{} = already -> {:ok, already}
      nil -> insert_attempt(story, attempt, issues)
    end
  end

  # Compared as instants, not as strings. `to_string/1` on a DateTime renders
  # "2026-05-17 22:17:32.734931Z" while the payload carries the ISO8601
  # "2026-05-17T22:17:32.734931Z" — a space against a T. They never matched, so
  # every run inserted a fresh copy of every attempt and one project reached
  # 954 rows for 159 real ones before the audit caught it.
  defp same_instant?(%DateTime{} = recorded, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, parsed, _offset} -> DateTime.compare(recorded, parsed) == :eq
      _ -> false
    end
  end

  defp same_instant?(_recorded, _iso), do: false

  defp insert_attempt(story, attempt, issues) do
    %QaAttempt{}
    |> QaAttempt.changeset(%{
      story_id: story.id,
      status: attempt["status"],
      scenarios: attempt["scenarios"],
      issue_ids: remap_issue_ids(attempt["issue_local_ids"], issues),
      agent_id: attempt["agent_id"],
      task_id: attempt["task_id"],
      submitted_at: attempt["submitted_at"]
    })
    |> Repo.insert()
  end

  # An issue this run did not create is dropped rather than carried as a
  # dangling id. The attempt still records that it failed and what it said; it
  # simply cannot point at a row that is not here.
  defp remap_issue_ids(nil, _issues), do: []

  defp remap_issue_ids(local_ids, issues) do
    local_ids
    |> Enum.map(&(issues[&1] && issues[&1].id))
    |> Enum.reject(&is_nil/1)
  end

  defp put_rules(scope, rules, stories) do
    collect(rules, fn rule -> put_rule(scope, stories[rule["story_local_id"]], rule) end)
  end

  defp put_rule(_scope, nil, rule), do: {:error, {:unknown_story, rule["story_local_id"]}}

  defp put_rule(scope, story, rule) do
    scope
    |> BddRules.list_rules_for_story(story.id)
    |> Enum.find(&(&1.statement == rule["statement"]))
    |> reuse_or_create_rule(scope, story, rule)
  end

  defp reuse_or_create_rule(%{} = already, _scope, _story, _rule), do: {:ok, already}

  defp reuse_or_create_rule(nil, scope, story, rule),
    do: BddRules.create_rule(scope, story.id, attrs(rule, BddRules.Rule))

  # Idempotent across runs without collapsing duplicates within one.
  #
  # Sam's real project has four scenarios sharing a description with a sibling
  # under the same story. Matching on text alone dropped them — and still
  # counted them as migrated, so the summary said 658 while 654 arrived, which
  # is the one number he would have checked.
  #
  # So the rows that existed before this run are snapshotted per story and
  # consumed as they are matched. A second migration finds its own earlier rows
  # and reuses them one for one; two identical scenarios in the payload consume
  # two, or insert a second. Nothing is deduped that was not already there.
  defp put_criteria(scope, criteria, stories, rules) do
    snapshots =
      stories
      |> Map.values()
      |> Map.new(&{&1.id, AcceptanceCriteria.list_story_criteria(scope, &1.id)})

    criteria
    |> Enum.reduce_while({:ok, %{}, snapshots}, fn criterion, {:ok, acc, snaps} ->
      put_criterion(scope, stories[criterion["story_local_id"]], criterion, rules, acc, snaps)
    end)
    |> case do
      {:ok, acc, _snaps} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_criterion(_scope, nil, criterion, _rules, _acc, _snaps),
    do: {:halt, {:error, {:unknown_story, criterion["story_local_id"]}}}

  defp put_criterion(scope, story, criterion, rules, acc, snaps) do
    {match, snaps} = take_match(snaps, story.id, criterion["description"])

    match
    |> reuse_or_create_criterion(scope, story, criterion, rules)
    |> step(acc, snaps, criterion["local_id"])
  end

  defp step({:ok, record}, acc, snaps, local_id),
    do: {:cont, {:ok, Map.put(acc, local_id, record), snaps}}

  defp step({:error, reason}, _acc, _snaps, _local_id), do: {:halt, {:error, reason}}

  # A criterion already here still takes its kind. Matching one and returning it
  # untouched left 912 of them without the field the moment it started being
  # exported — the same way stories stayed parked and nine links stayed stale.
  defp reuse_or_create_criterion(%{} = already, scope, _story, criterion, _rules) do
    resync(
      already,
      criterion,
      [:kind, :verified, :verified_at, :spec_path],
      &AcceptanceCriteria.update_criterion(scope, &1, &2)
    )
  end

  defp reuse_or_create_criterion(nil, scope, story, criterion, rules) do
    criterion
    |> attrs(AcceptanceCriteria.Criterion)
    |> put_ref(:rule_id, rules[criterion["rule_local_id"]])
    |> then(&AcceptanceCriteria.create_criterion(scope, story, &1))
  end

  defp take_match(snapshots, story_id, description) do
    rows = Map.get(snapshots, story_id, [])

    case Enum.split_with(rows, &(&1.description == description)) do
      {[hit | rest_hits], others} ->
        {hit, Map.put(snapshots, story_id, rest_hits ++ others)}

      {[], _} ->
        {nil, snapshots}
    end
  end

  defp put_personas(scope, personas) do
    existing = Personas.list_personas(scope)

    collect(personas, fn persona ->
      # Matched on slug or name, because the harness derives its own slug and
      # the one the payload carried may not be the one it kept. Missing here is
      # not a near miss: the unique index catches it instead, and a constraint
      # violation inside the transaction takes the whole migration down.
      case Enum.find(existing, &(&1.slug == persona["slug"] or &1.name == persona["name"])) do
        %{} = already ->
          resync(already, persona, [:headline], &Personas.update_persona(scope, &1, &2))

        nil ->
          Personas.create_persona(scope, attrs(persona, Personas.Persona))
      end
    end)
  end

  defp link_personas(scope, links, stories, personas) do
    Enum.reduce_while(links, :ok, fn link, _acc ->
      with %{} = persona <- personas[link["persona_local_id"]],
           %{} = story <- stories[link["story_local_id"]],
           :ok <- ensure_linked(scope, persona, story) do
        {:cont, :ok}
      else
        nil -> {:halt, {:error, {:unknown_persona_link, link}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A link that already exists is the migration being run twice, which the
  # story explicitly allows. Inserting it again trips a unique constraint and
  # takes the whole transaction down with it.
  defp ensure_linked(scope, persona, story) do
    if Enum.any?(Personas.list_personas_for_story(scope, story.id), &(&1.id == persona.id)) do
      :ok
    else
      case Personas.link_persona_to_story(scope, persona.id, story.id) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @wire_only ~w(local_id story_local_id rule_local_id epic_local_id persona_local_id)

  # local_id is the wire's business, not the schema's, so it is dropped here.
  #
  # Atom keys, because the contexts merge their own atom keys (:project_id,
  # :story_id) into whatever they are handed, and Ecto refuses a map with
  # mixed keys. `to_existing_atom` rather than `to_atom`: the wire is external
  # input, and an unknown field is dropped rather than allowed to grow the atom
  # table.
  # Keyed by the schema's own field list rather than by converting strings to
  # atoms. The wire is external input: `to_existing_atom` would need a rescue to
  # be safe, and asking the schema what it accepts is both narrower and honest —
  # a field the schema does not have is not a field, whatever the sender called
  # it.
  defp attrs(record, schema) do
    allowed = schema.__schema__(:fields)

    record
    |> Map.drop(@wire_only)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case Enum.find(allowed, &(to_string(&1) == to_string(key))) do
        nil -> acc
        field -> Map.put(acc, field, value)
      end
    end)
  end

  defp put_ref(attrs, _key, nil), do: attrs
  defp put_ref(attrs, key, record), do: Map.put(attrs, key, record.id)

  defp collect(records, fun) do
    Enum.reduce_while(records, {:ok, %{}}, fn record, {:ok, acc} ->
      case fun.(record) do
        {:ok, created} -> {:cont, {:ok, Map.put(acc, record["local_id"], created)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
