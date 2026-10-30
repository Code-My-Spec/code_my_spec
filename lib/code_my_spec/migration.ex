defmodule CodeMySpec.Migration do
  @moduledoc """
  Copies a project's authored records from a local harness onto the cloud.

  What travels is what the user authored: stories, epics, personas and their
  story links, rules, criteria, issues, questions, QA attempts, components and
  their dependencies, and the components-authored stamp. What does not
  (`derived_kinds/0`) is everything the harness recomputes — the cloud rebuilds
  it from the working copy on first sync.

  One call, one transaction: a refused or failed import writes nothing.
  Re-running is safe — every kind is matched against what is already here.

  Local ids mean nothing on the cloud, so every reference is rewritten as the
  graph lands, in a fixed insert order. See knowledge/promotion, "Migration".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Stories,
      CodeMySpec.Auth,
      CodeMySpec.BddRules,
      CodeMySpec.Components,
      CodeMySpec.Epics,
      CodeMySpec.Issues,
      CodeMySpec.Personas,
      CodeMySpec.Projects,
      CodeMySpec.Qa,
      CodeMySpec.Questions,
      CodeMySpec.Qa.QaAttempt,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope
    ],
    exports: [Client]

  import Ecto.Query, warn: false

  alias CodeMySpec.{
    BddRules,
    Epics,
    Issues,
    Personas,
    Questions,
    Repo,
    Stories
  }

  alias CodeMySpec.Stories.AcceptanceCriteria

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.QaAttempts
  alias CodeMySpec.Users.Scope

  @derived ~w(files problems sessions requirements analysis_runs file_edits)

  @doc "Kinds the harness recomputes, which this deliberately does not carry."
  @spec derived_kinds() :: [String.t()]
  def derived_kinds, do: @derived

  @doc """
  Read one project's authored graph off the local harness.

  Reads through the contexts rather than the database: the local harness runs
  this same code over SQLite, so there are no second queries to drift.

  Local ids travel as `local_id` and are the only thing tying the payload
  together. Reads nothing outside this project.
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
      "issues" => export_issues(scope),
      "questions" => Enum.flat_map(stories, &export_questions(scope, &1)),
      "qa_attempts" => Enum.flat_map(stories, &export_qa_attempts(scope, &1)),
      "components" => export_components(scope),
      "dependencies" => export_dependencies(scope),
      "components_authored_at" => components_authored_at(scope)
    }
  end

  # By module name throughout: ids are derived from the project id, so the far
  # side's differ, and the module name is the key both sides agree on (see
  # `component_id/2`).
  defp export_components(scope) do
    components = Components.list_components(scope)
    names = Map.new(components, &{&1.id, &1.module_name})

    Enum.map(
      components,
      &%{
        "module_name" => &1.module_name,
        "name" => &1.name,
        "type" => &1.type,
        "description" => &1.description,
        "provenance" => &1.provenance && to_string(&1.provenance),
        "parent_module_name" => names[&1.parent_component_id]
      }
    )
  end

  defp export_dependencies(scope) do
    scope
    |> Components.list_dependencies()
    |> Enum.map(
      &%{
        "source_module_name" => &1.source_component.module_name,
        "target_module_name" => &1.target_component.module_name,
        "provenance" => &1.provenance && to_string(&1.provenance)
      }
    )
  end

  defp components_authored_at(%Scope{active_project_id: id}) when is_binary(id),
    do: Repo.one(from(p in Project, where: p.id == ^id, select: p.components_authored_at))

  defp components_authored_at(_scope), do: nil

  # One walk per export (memoised in the process dictionary), keyed by the
  # criterion id in each filename. On a server there is no disk, and each
  # criterion keeps the `spec_path` it already recorded.
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
        "observation" => scenario.observation,
        "blocker_issue_local_id" => scenario.blocker_issue_id
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
      # All authored state: `ready_for_dev` is what releases a story into the
      # requirement graph.
      "ready_for_dev" => story.ready_for_dev,
      "specs_ready" => story.specs_ready,
      "notes" => story.notes,
      "priority" => story.priority,
      "epic_local_id" => story.epic_id,
      # By module name, not id: component ids are derived from the project id,
      # so they differ across the move.
      "component_module_name" => story.component && story.component.module_name
    }

  defp export_epic(epic),
    do: %{
      "local_id" => epic.id,
      "name" => epic.name,
      # Carried, not re-derived from the name: both are authored.
      "slug" => epic.slug,
      "description" => epic.description
    }

  defp export_persona(persona),
    do: %{
      "local_id" => persona.id,
      "name" => persona.name,
      "slug" => persona.slug,
      # `persona_type` separates a proto sketch from a researched persona.
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
    |> AcceptanceCriteria.list_all_story_criteria(story.id)
    |> Enum.map(
      &%{
        "local_id" => &1.id,
        # The criterion's name for life. Specs on disk name it, so it crosses
        # unchanged where `local_id` does not. Retired ones cross too, so their
        # numbers stay taken.
        "number" => &1.number,
        "retired_at" => &1.retired_at,
        "story_local_id" => story.id,
        "rule_local_id" => &1.rule_id,
        "description" => &1.description,
        "body" => &1.body,
        # The real filename, never re-derived: a derived path depends on the
        # id (which the move changes) and on a slug of editable text.
        "spec_path" => &1.spec_path || Map.get(spex, to_string(&1.id)),
        "kind" => &1.kind && to_string(&1.kind),
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
    with :ok <- require_paid_plan(scope) do
      do_import(scope, payload)
    end
  end

  @doc "Import a JSON file within a transaction that always rolls back."
  def dry_run_file(%Scope{} = scope, path) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, payload} when is_map(payload) <- Jason.decode(json) do
      dry_run_project(scope, payload)
    else
      {:ok, _} -> {:error, :invalid_export}
      {:error, reason} -> {:error, reason}
    end
  end

  def dry_run_project(%Scope{} = scope, payload) when is_map(payload) do
    {:error, {:dry_run, result}} =
      Repo.transaction(fn ->
        result = import_project(scope, payload)
        Repo.rollback({:dry_run, result})
      end)

    report =
      case result do
        {:ok, summary} ->
          %{status: :imported, counts: Map.delete(summary, :skipped), refused: nil}

        {:error, reason} ->
          %{status: :refused, counts: nil, refused: inspect(reason)}
      end

    {:ok, Map.put(report, :rolled_back, true)}
  end

  # Checked before the transaction opens, so a refused migration writes
  # nothing, and refused as `:plan_required` rather than a validation error
  # that would read as malformed data. Billing is not part of this path.
  defp require_paid_plan(%Scope{active_account: %{plan: :free}}), do: {:error, :plan_required}
  defp require_paid_plan(_scope), do: :ok

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

  # The authored graph, in the order references demand: components before
  # stories (their link), epics before stories, personas linked before criteria
  # (a criterion needs a persona-linked story, `:persona_linkage_required`),
  # rules before criteria.
  defp put_graph(scope, payload) do
    with {:ok, components} <- put_components(scope, payload["components"] || []),
         {:ok, dependencies} <-
           put_dependencies(scope, payload["dependencies"] || [], components),
         :ok <- stamp_frozen(scope, payload["components_authored_at"]),
         {:ok, epics} <- put_epics(scope, payload["epics"] || []),
         {:ok, stories} <- put_stories(scope, payload["stories"] || [], epics),
         {:ok, personas} <- put_personas(scope, payload["personas"] || []),
         :ok <- link_personas(scope, payload["persona_stories"] || [], stories, personas),
         {:ok, rules} <- put_rules(scope, payload["rules"] || [], stories),
         {:ok, criteria} <- put_criteria(scope, payload["criteria"] || [], stories, rules) do
      {:ok,
       %{
         components: components,
         dependencies: dependencies,
         epics: epics,
         stories: stories,
         personas: personas,
         rules: rules,
         criteria: criteria
       }}
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

  # Components first, so a story's link (`component_id/2`) names a row that is
  # already here. Upserted on module name, the natural key, so a second run
  # finds its own; parents in a second pass, once every component exists.
  defp put_components(scope, components) do
    with {:ok, by_name} <- upsert_components(scope, components),
         :ok <- set_parents(scope, components, by_name) do
      {:ok, by_name}
    end
  end

  defp upsert_components(scope, components) do
    Enum.reduce_while(components, {:ok, %{}}, fn c, {:ok, acc} ->
      attrs =
        c
        |> Map.take(~w(module_name name type description provenance))
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

      case Components.upsert_component(scope, attrs) do
        %Component{} = component -> {:cont, {:ok, Map.put(acc, component.module_name, component)}}
        {:error, reason} -> {:halt, {:error, {:component, c["module_name"], reason}}}
      end
    end)
  end

  defp set_parents(scope, components, by_name) do
    Enum.reduce_while(components, :ok, fn c, :ok ->
      with %Component{} = child <- by_name[c["module_name"]],
           %Component{id: parent_id} <- by_name[c["parent_module_name"]],
           false <- child.parent_component_id == parent_id,
           {:error, reason} <-
             Components.update_component(scope, child, %{parent_component_id: parent_id}) do
        {:halt, {:error, {:component_parent, c["module_name"], reason}}}
      else
        _ -> {:cont, :ok}
      end
    end)
  end

  # An edge whose ends are not both here is dropped: a dependency on a
  # component that did not travel would point at nothing.
  defp put_dependencies(scope, dependencies, by_name) do
    existing =
      scope
      |> Components.list_dependencies()
      |> MapSet.new(&{&1.source_component_id, &1.target_component_id})

    Enum.reduce_while(dependencies, {:ok, %{}}, fn d, {:ok, acc} ->
      with %Component{id: source} <- by_name[d["source_module_name"]],
           %Component{id: target} <- by_name[d["target_module_name"]] do
        put_dependency(scope, existing, source, target, d["provenance"], acc)
      else
        _ -> {:cont, {:ok, acc}}
      end
    end)
  end

  defp put_dependency(scope, existing, source, target, provenance, acc) do
    if MapSet.member?(existing, {source, target}) do
      {:cont, {:ok, Map.put(acc, {source, target}, :kept)}}
    else
      case Components.create_dependency(scope, %{
             source_component_id: source,
             target_component_id: target,
             provenance: provenance
           }) do
        {:ok, dependency} -> {:cont, {:ok, Map.put(acc, {source, target}, dependency)}}
        {:error, reason} -> {:halt, {:error, {:dependency, source, target, reason}}}
      end
    end
  end

  # A project frozen at the source is frozen here, or the destination's first
  # sync would treat its spec files as the description of its components again.
  # A project already stamped here keeps its own stamp.
  defp stamp_frozen(_scope, nil), do: :ok

  defp stamp_frozen(%Scope{active_project_id: id}, stamp) do
    with {:ok, at} <- instant(stamp) do
      from(p in Project, where: p.id == ^id and is_nil(p.components_authored_at))
      |> Repo.update_all(set: [components_authored_at: at])

      :ok
    end
  end

  # A DateTime when called directly, its ISO8601 string once through the wire.
  defp instant(%DateTime{} = at), do: {:ok, at}

  defp instant(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> {:error, {:components_authored_at, iso}}
    end
  end

  # Each `put_*` returns a map of local_id => the record the cloud created, and
  # every later step reads references out of those maps, never the payload.
  # That is the remapping.

  # Epics are unique on (project_id, name): a second run reuses by name.
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

    stories
    |> Enum.reduce_while({:ok, %{}, %{}}, fn story, {:ok, acc, made} ->
      case put_story(scope, story, known, made, epics) do
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

  # `known` is the destination before this run; `made` is what this run has
  # created, by title. The same source story twice reuses its row; two
  # different source stories sharing a title cannot both exist under the unique
  # index, so the import refuses with `:duplicate_title`, naming both.
  defp put_story(scope, story, known, made, epics) do
    case Map.get(made, story["title"]) do
      nil -> create_or_relink(scope, story, known, epics)
      {local_id, created} -> adopt_or_conflict(local_id, created, story)
    end
  end

  defp adopt_or_conflict(local_id, created, %{"local_id" => local_id}), do: {:ok, created}

  defp adopt_or_conflict(local_id, _created, story) do
    {:error, {:duplicate_title, story["title"], local_id, story["local_id"]}}
  end

  defp create_or_relink(scope, story, known, epics) do
    case find_existing(known, story) do
      %{} = already ->
        relink(scope, already, epics, story)

      nil ->
        story
        |> attrs(Stories.Story)
        |> fit_story_to_cap()
        |> put_ref(:epic_id, epics[story["epic_local_id"]])
        |> put_component(scope, story["component_module_name"])
        |> Map.put(:migrated_from_id, story["local_id"])
        |> then(&Stories.create_story(scope, &1))
    end
  end

  # Stories written before the 600-character cap carry mechanism in the story
  # field; the cap refuses them, and with them the whole migration. The full
  # text moves to `notes` (uncapped), and the story keeps its sentence.
  @story_cap 600

  defp fit_story_to_cap(attrs) do
    text = attrs[:story] || attrs[:description] || ""

    if String.length(text) > @story_cap do
      short = first_sentences(text)

      attrs
      |> Map.put(:story, short)
      |> Map.put(:description, short)
      |> Map.put(
        :notes,
        Enum.join(Enum.reject([text, attrs[:notes]], &(&1 in [nil, ""])), "\n\n")
      )
    else
      attrs
    end
  end

  defp first_sentences(text) do
    head = String.slice(text, 0, @story_cap)

    case Regex.scan(~r/[.!?](?=\s)/u, head, return: :index) |> List.last() do
      [{at, 1}] when at > 200 -> binary_part(head, 0, at + 1)
      _ -> String.slice(text, 0, @story_cap - 3) <> "..."
    end
  end

  # A story already here still takes its authored state from the payload
  # (component, epic, readiness, priority, notes), so a re-run carries
  # corrections. Title, narrative and description are not re-applied: they
  # are edited at the destination once a project has moved.
  defp relink(scope, story, epics, payload) do
    story
    |> resync_attrs(scope, epics, payload)
    |> case do
      changes when map_size(changes) == 0 -> {:ok, story}
      changes -> Stories.update_story(scope, story, changes)
    end
  end

  # The same rule for entities reused by a plain find: a row already here takes
  # the payload's values for `keys`, so a field added to the export later still
  # reaches rows migrated before it.
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

  defp resync_attrs(story, scope, epics, payload) do
    epic = epics[payload["epic_local_id"]]

    %{}
    |> put_changed(story, :component_id, component_id(scope, payload["component_module_name"]))
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

  # `migrated_from_id` (the source's own id, never edited here) is the key;
  # title is the fallback for rows written before the id was recorded.
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

  # Title decides only for a row that cannot say where it came from. A row
  # naming a different source story is not this one: nil sends it to the
  # insert, where the unique title index rolls the import back — loud rather
  # than a silent merge.
  defp match_by_title(nil, _story), do: nil

  defp match_by_title(%{migrated_from_id: nil} = candidate, _story), do: candidate

  defp match_by_title(%{migrated_from_id: source_id} = candidate, story) do
    if source_id == story["local_id"], do: candidate, else: nil
  end

  # The link is set from the computed id whether or not the component row
  # exists; a component is never invented from a name.
  defp put_component(attrs, scope, module_name) do
    put_component_id(attrs, component_id(scope, module_name))
  end

  defp put_component_id(attrs, nil), do: attrs
  defp put_component_id(attrs, id), do: Map.put(attrs, :component_id, id)

  # Computed, not looked up: `Component.deterministic_id/2` is a UUIDv5 of the
  # project and module name, so it names the component whether or not its row
  # exists yet, and cannot be carried across (the project id changes).
  # `stories.component_id` has no foreign key; a link to a component that never
  # appears reads unsatisfied, since `component_linked` checks it exists.
  defp component_id(_scope, nil), do: nil
  defp component_id(_scope, ""), do: nil

  defp component_id(%Scope{active_project_id: project_id}, module_name),
    do: Component.deterministic_id(project_id, module_name)

  # The destination's stories before this run, for `index_stories/1`.
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

  # Matched on `submitted_at` within a story (microsecond precision; an attempt
  # is never edited). `issue_ids` are rewritten against what this run created.
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

  # Compared as instants, not strings: `to_string/1` renders a space where the
  # payload's ISO8601 has a `T`, and every re-run would duplicate every attempt.
  defp same_instant?(%DateTime{} = recorded, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, parsed, _offset} -> DateTime.compare(recorded, parsed) == :eq
      _ -> false
    end
  end

  defp same_instant?(_recorded, _iso), do: false

  defp insert_attempt(story, attempt, issues) do
    %QaAttempt{}
    |> QaAttempt.import_changeset(%{
      story_id: story.id,
      status: attempt["status"],
      scenarios: remap_scenarios(attempt["scenarios"], issues),
      issue_ids: remap_issue_ids(attempt["issue_local_ids"], issues),
      agent_id: attempt["agent_id"],
      task_id: attempt["task_id"],
      submitted_at: attempt["submitted_at"]
    })
    |> Repo.insert()
  end

  # A blocked scenario must name its blocker issue, and the issue's id here is
  # not the local one, so it is rewritten like every other reference.
  defp remap_scenarios(nil, _issues), do: nil

  defp remap_scenarios(scenarios, issues) do
    Enum.map(scenarios, fn scenario ->
      {local_id, scenario} = Map.pop(scenario, "blocker_issue_local_id")
      Map.put(scenario, "blocker_issue_id", issues[local_id] && issues[local_id].id)
    end)
  end

  # An issue this run did not create is dropped rather than left dangling.
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

  # Idempotent across runs without collapsing duplicates within one: rows that
  # existed before this run are snapshotted per story and consumed as matched,
  # so two criteria sharing a description reuse two rows or insert a second.
  defp put_criteria(scope, criteria, stories, rules) do
    snapshots =
      stories
      |> Map.values()
      |> Map.new(&{&1.id, AcceptanceCriteria.list_all_story_criteria(scope, &1.id)})

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

  # A criterion already here still takes its exported fields (`resync/4`).
  defp reuse_or_create_criterion(%{} = already, scope, _story, criterion, _rules) do
    resync(
      already,
      criterion,
      [:kind, :verified, :verified_at, :spec_path, :number, :retired_at],
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
      # Slug or name: the destination derives its own slug. A miss here hits
      # the unique index and rolls the whole migration back.
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

  # An existing link is a re-run; inserting it again would trip the unique
  # constraint and roll the transaction back.
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

  # Wire-only keys dropped; the rest mapped to the schema's own atom fields
  # (contexts merge atom keys, and Ecto refuses mixed keys). The wire is
  # external input, so a key the schema does not have is dropped, never
  # turned into an atom.
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
