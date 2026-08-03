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

  alias CodeMySpec.{AcceptanceCriteria, BddRules, Epics, Personas, Repo, Stories}
  alias CodeMySpec.Users.Scope

  @derived ~w(files problems sessions components requirements analysis_runs file_edits)

  @doc "Kinds the harness recomputes, which this deliberately does not carry."
  @spec derived_kinds() :: [String.t()]
  def derived_kinds, do: @derived

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
  defp plan(%Scope{active_account: %{plan: plan}}), do: plan
  defp plan(_scope), do: nil

  defp do_import(scope, payload) do
    Repo.transaction(fn ->
      # Personas and their links come before criteria, not after. A criterion
      # cannot be created for a story with no linked persona — the harness
      # refuses with :persona_linkage_required, because a scenario without a
      # persona has no voice. Ordering here is a real dependency, not a
      # preference: rules need stories, criteria need rules AND a persona-linked
      # story, and stories need their epic.
      with {:ok, epics} <- put_epics(scope, payload["epics"] || []),
           {:ok, stories} <- put_stories(scope, payload["stories"] || [], epics),
           {:ok, personas} <- put_personas(scope, payload["personas"] || []),
           :ok <- link_personas(scope, payload["persona_stories"] || [], stories, personas),
           {:ok, rules} <- put_rules(scope, payload["rules"] || [], stories),
           {:ok, criteria} <- put_criteria(scope, payload["criteria"] || [], stories, rules) do
        %{
          epics: map_size(epics),
          stories: map_size(stories),
          rules: map_size(rules),
          criteria: map_size(criteria),
          personas: map_size(personas),
          skipped: @derived
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Each of these returns a map of local_id => the record the cloud created, and
  # every later step reads references out of those maps rather than out of the
  # payload. That is the remapping, and keeping it in one shape per kind is what
  # stops it leaking into the individual inserts.

  defp put_epics(scope, epics),
    do: collect(epics, &Epics.create_epic(scope, attrs(&1, Epics.Epic)))

  defp put_stories(scope, stories, epics) do
    existing = scope |> project_stories() |> Map.new(&{&1.title, &1})

    collect(stories, fn story ->
      case existing[story["title"]] do
        %{} = already ->
          {:ok, already}

        nil ->
          story
          |> attrs(Stories.Story)
          |> put_ref(:epic_id, epics[story["epic_local_id"]])
          |> then(&Stories.create_story(scope, &1))
      end
    end)
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

  defp put_rules(scope, rules, stories) do
    collect(rules, fn rule ->
      case stories[rule["story_local_id"]] do
        nil ->
          {:error, {:unknown_story, rule["story_local_id"]}}

        story ->
          case Enum.find(
                 BddRules.list_rules_for_story(scope, story.id),
                 &(&1.statement == rule["statement"])
               ) do
            %{} = already -> {:ok, already}
            nil -> BddRules.create_rule(scope, story.id, attrs(rule, BddRules.Rule))
          end
      end
    end)
  end

  defp put_criteria(scope, criteria, stories, rules) do
    collect(criteria, fn criterion ->
      case stories[criterion["story_local_id"]] do
        nil ->
          {:error, {:unknown_story, criterion["story_local_id"]}}

        story ->
          case Enum.find(
                 AcceptanceCriteria.list_story_criteria(scope, story.id),
                 &(&1.description == criterion["description"])
               ) do
            %{} = already ->
              {:ok, already}

            nil ->
              criterion
              |> attrs(AcceptanceCriteria.Criterion)
              |> put_ref(:rule_id, rules[criterion["rule_local_id"]])
              |> then(&AcceptanceCriteria.create_criterion(scope, story, &1))
          end
      end
    end)
  end

  defp put_personas(scope, personas) do
    existing = Personas.list_personas(scope)

    collect(personas, fn persona ->
      # Matched on slug or name, because the harness derives its own slug and
      # the one the payload carried may not be the one it kept. Missing here is
      # not a near miss: the unique index catches it instead, and a constraint
      # violation inside the transaction takes the whole migration down.
      case Enum.find(existing, &(&1.slug == persona["slug"] or &1.name == persona["name"])) do
        %{} = already -> {:ok, already}
        nil -> Personas.create_persona(scope, attrs(persona, Personas.Persona))
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
