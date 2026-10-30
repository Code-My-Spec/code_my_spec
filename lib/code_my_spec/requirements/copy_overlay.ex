defmodule CodeMySpec.Requirements.CopyOverlay do
  @moduledoc """
  A checkout's file verdicts, computed by its harness from its own scan and
  reported as the copy's overlay.

  `verdicts/2` reads no database: the harness runs it on its scan and the
  records served with its read model (`records/1`). Both sides settle through
  `Handlers.copy_verdicts/1`, so the code is the same.

  The server stores each report (`report/2`); readers take it when it answers
  the current records, else compute the same verdicts from the copy's File rows
  (`verdicts_at/1`).
  See knowledge/requirements_graph/overlay.md.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias CodeMySpec.Files
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.CopyOverlay.Cache
  alias CodeMySpec.Requirements.CopyOverlay.Report
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.Profiles
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @doc """
  The records the file verdicts read beyond the scan, in wire form: live
  criteria numbers by story (oldest first), whether a component is authored,
  and the story numbers and context names a proposal may name.
  """
  @spec records(Scope.t()) :: map()
  def records(%Scope{} = scope) do
    architecture = Profiles.load(scope, :architecture)

    %{
      "criteria_by_story" =>
        Map.new(Profiles.criteria(scope), fn {story_id, criteria} ->
          {story_id, Enum.map(criteria, & &1.number)}
        end),
      "authored" => architecture.authored?,
      "story_numbers" => architecture.story_numbers,
      "context_names" => architecture.context_names
    }
  end

  @doc """
  The read model a harness is served, as the struct and as its wire payload
  with the payload's `"fingerprint"`. The fingerprint is how a report says
  which records it answers, and how a reader tells a stale report.

  Nothing in the payload may be a struct: `story_ids` crosses as a list, and a
  component as the fields the harness scanner reads for ownership and
  proposal validation.
  """
  @spec served_read_model(Scope.t()) :: {ReadModel.t(), map()}
  def served_read_model(%Scope{} = scope) do
    read_model = %{Files.read_model(scope) | overlay_records: records(scope)}

    payload = %{
      "component_by_module" => read_model.component_by_module,
      "component_by_id" => Map.new(read_model.component_by_id, &served_component/1),
      "story_ids" => MapSet.to_list(read_model.story_ids),
      "story_ids_by_number" => read_model.story_ids_by_number,
      "story_by_spec_path" => read_model.story_by_spec_path,
      "strict" => read_model.strict?,
      "overlay_records" => read_model.overlay_records
    }

    fingerprint =
      payload |> :erlang.term_to_binary() |> :erlang.md5() |> Base.encode16(case: :lower)

    {%{read_model | fingerprint: fingerprint}, Map.put(payload, "fingerprint", fingerprint)}
  end

  defp served_component({id, component}) do
    {id,
     %{"module_name" => Map.get(component, :module_name), "type" => Map.get(component, :type)}}
  end

  @doc """
  The checkout's file verdicts in wire form, one sweep per requirement, from
  its scan and the read model it was handed. `nil` when the read model carries
  no records (a server from before overlays).
  """
  @spec verdicts([map()], ReadModel.t()) :: [map()] | nil
  def verdicts(_observations, %ReadModel{overlay_records: nil}), do: nil

  def verdicts(observations, %ReadModel{overlay_records: records} = read_model) do
    # As the server keeps them: owners resolved, the criterion a spex names,
    # and validation output as it reads after crossing the wire.
    files =
      observations
      |> Scanner.resolve_owners(read_model)
      |> Enum.map(&as_synced/1)

    components = Enum.map(read_model.component_by_id, fn {id, c} -> Map.put(c, :id, id) end)

    %{
      files: Profiles.files_profile(files, nil, components, []),
      stories: %{amigos: %{criteria_by_story: criteria(records["criteria_by_story"])}},
      architecture: %{
        authored?: records["authored"] == true,
        story_numbers: records["story_numbers"] || [],
        context_names: records["context_names"] || []
      }
    }
    |> Handlers.copy_verdicts()
    |> Enum.map(&encode/1)
  end

  @doc """
  What `verdicts/2` reads of a scan, for holding between scans: a whole scan
  is about 6 MB, most of it what code files' validation recorded, which no
  file verdict reads.
  """
  @spec retained([map()]) :: [map()]
  def retained(observations), do: Enum.map(observations, &retain/1)

  # Code files are read for their owner alone: the module they declare.
  defp retain(%{role: role} = entry) when role in [:implementation, :test] do
    entry
    |> Map.take([:path, :role, :valid])
    |> Map.put(:validation_errors, declared(entry))
  end

  # A spex, for the criterion it names.
  defp retain(%{role: :bdd_spec} = entry) do
    entry
    |> Map.take([:path, :role, :valid])
    |> Map.put(:validation_errors, kept_data(entry, "criterion"))
  end

  defp retain(entry), do: Map.take(entry, [:path, :role, :valid, :size, :validation_errors])

  defp declared(entry), do: kept_data(entry, "module_name")

  defp kept_data(%{validation_errors: %{"data" => %{} = data}}, key) when is_map_key(data, key),
    do: %{"data" => Map.take(data, [key])}

  defp kept_data(_entry, _key), do: nil

  defp as_synced(entry) do
    errors = entry |> Map.get(:validation_errors) |> json()
    entry = Map.put(entry, :validation_errors, errors)
    Map.put(entry, :criterion_number, criterion_named(entry))
  end

  # `SpecBinding.bind/2`'s number, without its lookup.
  defp criterion_named(%{role: :bdd_spec, validation_errors: %{"data" => %{"criterion" => n}}})
       when is_integer(n),
       do: n

  defp criterion_named(_entry), do: nil

  defp criteria(by_story) do
    Map.new(by_story || %{}, fn {story_id, numbers} ->
      {to_integer(story_id), Enum.map(numbers, &%{number: &1})}
    end)
  end

  defp to_integer(id) when is_integer(id), do: id
  defp to_integer(id) when is_binary(id), do: String.to_integer(id)

  defp encode(sweep) do
    %{
      "type" => sweep.entity_type,
      "name" => sweep.name,
      "default" => sweep.default,
      "default_details" => json(sweep.default_details),
      "except" => Enum.map(sweep.except, &[&1.entity_id, &1.satisfied, json(&1.details)])
    }
  end

  defp json(nil), do: nil
  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  @doc """
  Store a checkout's report, replacing its last.
  """
  @spec report(Scope.t(), map()) :: {:ok, Report.t()} | {:error, term()}
  def report(%Scope{active_working_copy_id: copy, active_project_id: project}, payload)
      when is_binary(copy) and is_binary(project) do
    now = DateTime.utc_now()

    %Report{working_copy_id: copy, clean_reports: 0}
    |> Report.changeset(%{
      project_id: project,
      read_model: payload["read_model"],
      head: payload["head"],
      behind: payload["behind"],
      dirty: payload["dirty"],
      verdicts: :erlang.term_to_binary(payload["verdicts"], [:compressed]),
      reported_at: now
    })
    |> Repo.insert(
      on_conflict:
        {:replace, ~w(project_id read_model head behind dirty verdicts reported_at updated_at)a},
      conflict_target: :working_copy_id
    )
  end

  def report(_scope, _payload), do: {:error, :no_copy}

  @doc """
  The file verdicts a reader at the scope's vantage sees: its copy's, or for
  `nil` the copy the project reads from (`WorkingCopies.reading_copy_id/1`).

  The harness's report when it answers the records as they are now (its
  `read_model` fingerprint is current). Otherwise computed here, by the same
  code, from the copy's File rows: a harness too old to report, one not yet
  restarted, or none at all still reads a complete graph from its last
  manifest; a copy with no File rows reads as an empty checkout, as its rows
  did. Computed verdicts are kept per copy until the records or the copy's
  files move. `:no_checkout` for `nil` when no copy speaks for the project.
  """
  @spec verdicts_at(Scope.t()) ::
          {:reported | :computed, [map()], NaiveDateTime.t() | nil} | :no_checkout
  def verdicts_at(%Scope{active_working_copy_id: nil} = scope) do
    case WorkingCopies.reading_copy_id(scope) do
      nil -> :no_checkout
      copy -> verdicts_at(%{scope | active_working_copy_id: copy})
    end
  end

  def verdicts_at(%Scope{active_working_copy_id: copy} = scope) do
    {read_model, _payload} = served_read_model(scope)

    case Repo.get(Report, copy) do
      %Report{read_model: fingerprint} = report when fingerprint == read_model.fingerprint ->
        {:reported, :erlang.binary_to_term(report.verdicts, [:safe]),
         DateTime.to_naive(report.reported_at)}

      _none_or_stale ->
        computed(copy, read_model)
    end
  end

  # What the copy's last manifest left, as the harness would have scanned it.
  defp computed(copy, read_model) do
    {synced_at, _count} =
      files =
      Repo.one(
        from(f in CodeMySpec.Files.File,
          where: f.working_copy_id == ^copy,
          select: {max(f.updated_at), count(f.id)}
        )
      )

    verdicts =
      Cache.fetch(copy, {read_model.fingerprint, files}, fn ->
        from(f in CodeMySpec.Files.File,
          where: f.working_copy_id == ^copy,
          select: map(f, [:path, :role, :valid, :validation_errors, :size])
        )
        |> Repo.all()
        |> verdicts(read_model)
      end)

    {:computed, verdicts, synced_at}
  end
end
