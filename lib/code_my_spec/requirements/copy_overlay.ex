defmodule CodeMySpec.Requirements.CopyOverlay do
  @moduledoc """
  A checkout's file verdicts, computed by its harness from its own scan and
  reported as the copy's overlay.

  `verdicts/2` reads no database: the harness runs it on its scan and the
  records served with its read model (`records/1`). Both sides settle through
  `Handlers.copy_verdicts/1`, so the code is the same.

  Shadow: the server stores each report (`report/2`) and compares it with its
  own rows for the checkout (`check/1`); nothing reads it.
  See knowledge/requirements_graph/overlay.md.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.CopyOverlay.Report
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Profiles
  alias CodeMySpec.Requirements.Verification
  alias CodeMySpec.Users.Scope

  @samples 5

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
  Store a checkout's report, replacing its last. The comparison count is
  cleared until `check/1` runs; the run of clean reports is kept.
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
      reported_at: now,
      mismatches: nil,
      compared_at: nil
    })
    |> Repo.insert(
      on_conflict:
        {:replace,
         ~w(project_id read_model head behind dirty verdicts reported_at mismatches compared_at updated_at)a},
      conflict_target: :working_copy_id
    )
  end

  def report(_scope, _payload), do: {:error, :no_copy}

  @doc """
  The overlay a reader at `vantage` sees: its copy's last report, or for `nil`
  the project's default copy's. `:awaiting` when that copy has not reported,
  `:no_checkout` when `nil` has no default copy to read.
  """
  @spec at(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:reported, [map()], DateTime.t()} | :awaiting | :no_checkout
  def at(project_id, nil) do
    case Repo.one(
           from(p in CodeMySpec.Projects.Project,
             where: p.id == ^project_id,
             select: p.default_working_copy_id
           )
         ) do
      nil -> :no_checkout
      copy -> at(project_id, copy)
    end
  end

  def at(_project_id, copy) do
    case Repo.get(Report, copy) do
      nil ->
        :awaiting

      report ->
        {:reported, :erlang.binary_to_term(report.verdicts, [:safe]), report.reported_at}
    end
  end

  @doc """
  Compare the checkout's last report with the server's own rows for it, once
  the projector has settled, and record the result on the report.
  """
  @spec check(Scope.t()) :: {:ok, map()} | {:error, :no_report}
  def check(%Scope{active_working_copy_id: copy, active_project_id: project}) do
    :ok = IncrementalGraph.settle(project, [copy])

    case Repo.get(Report, copy) do
      nil ->
        {:error, :no_report}

      report ->
        verdicts = :erlang.binary_to_term(report.verdicts, [:safe])
        result = compare(verdicts, rows(copy))
        record(report, result)
        log(copy, result)
        {:ok, result}
    end
  end

  @doc """
  How a report's verdicts agree with stored rows (`%{name, entity_type,
  entity_id, satisfied, details}`): every row is compared with its entity's
  exception, else its requirement's default. A requirement the report leaves
  out disagrees at every row.
  """
  @spec compare([map()], [map()]) :: %{compared: non_neg_integer(), mismatches: [map()]}
  def compare(verdicts, rows) do
    by_name = Map.new(verdicts, &{&1["name"], &1})

    mismatches =
      for row <- rows,
          reported = reported(Map.get(by_name, row.name), row),
          reported != stored(row),
          do: %{
            name: row.name,
            entity: {row.entity_type, row.entity_id},
            overlay: reported,
            server: stored(row)
          }

    %{compared: length(rows), mismatches: mismatches}
  end

  defp reported(nil, _row), do: :unreported
  defp reported(%{"type" => type}, %{entity_type: other}) when type != other, do: :unreported

  defp reported(sweep, row) do
    {satisfied, details} =
      case Enum.find(sweep["except"], fn [id | _] -> id == row.entity_id end) do
        [_id, satisfied, details] -> {satisfied, details}
        nil -> {sweep["default"], sweep["default_details"]}
      end

    Verification.stored(%{name: row.name, satisfied: satisfied, details: details})
  end

  defp stored(row),
    do: Verification.stored(%{name: row.name, satisfied: row.satisfied, details: row.details})

  # The checkout's own rows for the names a report carries, each with its owner.
  defp rows(copy) do
    names = Handlers.copy_names()

    from(n in {"requirements", Node},
      where: n.working_copy_id == type(^copy, Ecto.UUID) and n.name in ^names,
      select:
        map(n, [:name, :component_id, :story_id, :issue_id, :project_id, :satisfied, :details])
    )
    |> Repo.all()
    |> Enum.map(&owned/1)
  end

  defp owned(%{component_id: id} = row) when not is_nil(id), do: owner(row, "component", id)
  defp owned(%{story_id: id} = row) when not is_nil(id), do: owner(row, "story", id)
  defp owned(%{issue_id: id} = row) when not is_nil(id), do: owner(row, "issue", id)
  defp owned(row), do: owner(row, "project", row.project_id)

  defp owner(row, type, id), do: Map.merge(row, %{entity_type: type, entity_id: id})

  defp record(report, %{mismatches: mismatches}) do
    count = length(mismatches)

    report
    |> Report.changeset(%{
      mismatches: count,
      clean_reports: if(count == 0, do: report.clean_reports + 1, else: 0),
      compared_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp log(copy, %{compared: compared, mismatches: []}) do
    Logger.info("[CopyOverlay] copy #{copy}: #{compared} verdicts compared, 0 mismatches")
  end

  defp log(copy, %{compared: compared, mismatches: mismatches}) do
    Logger.warning(
      "[CopyOverlay] copy #{copy}: #{compared} verdicts compared, #{length(mismatches)} " <>
        "mismatches; first #{min(@samples, length(mismatches))}: " <>
        (mismatches |> Enum.take(@samples) |> Enum.map_join("; ", &sample/1))
    )
  end

  defp sample(%{name: name, entity: {type, id}, overlay: overlay, server: server}),
    do: "#{name} #{type} #{id}: overlay #{inspect(overlay)} server #{inspect(server)}"
end
