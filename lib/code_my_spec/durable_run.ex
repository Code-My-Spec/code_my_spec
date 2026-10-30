defmodule CodeMySpec.DurableRun do
  @moduledoc """
  Durable identity and event cursor for a harness-owned test process. A manifest
  is written before the child starts, then updated with its OS identity as soon
  as the port opens. Only a process with the same birth time and command may be
  adopted after a restart.
  """

  use Boundary, top_level?: true, deps: [CodeMySpec.Paths], exports: :all

  alias CodeMySpec.Paths

  @spec dir() :: String.t()
  def dir, do: Path.join(Paths.local_state_dir(), "runs")
  def manifest_path(id) when is_integer(id), do: Path.join(dir(), "#{id}.json")
  def stream_path(id) when is_integer(id), do: Path.join(dir(), "#{id}.jsonl")
  def output_path(id) when is_integer(id), do: Path.join(dir(), "#{id}.output")
  def exit_path(id) when is_integer(id), do: Path.join(dir(), "#{id}.exit")

  def begin_run(id, root, source, args, commit, tied_run_ids \\ []) when is_integer(id) do
    File.mkdir_p!(dir())
    File.write!(stream_path(id), "")
    File.write!(output_path(id), "")
    File.rm(exit_path(id))

    manifest = %{
      "run_id" => id,
      "root" => root,
      "source" => source,
      "args" => args,
      "tied_run_ids" => tied_run_ids,
      "start_commit" => commit,
      "offset" => 0,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "status" => "starting"
    }

    write_manifest(manifest)
    manifest
  end

  def attach_pid(id, pid) when is_integer(id) and is_integer(pid) do
    # The launch shell stays alive until the child exits, so its identity
    # remains stable while the next harness verifies this pid.
    with {:ok, manifest} <- read_manifest(id),
         {:ok, identity} <- identity(pid) do
      manifest
      |> Map.merge(%{"pid" => pid, "identity" => identity, "status" => "running"})
      |> write_manifest()
    end
  end

  def read_manifest(id) do
    with {:ok, data} <- File.read(manifest_path(id)),
         {:ok, %{} = manifest} <- Jason.decode(data) do
      {:ok, manifest}
    end
  end

  def for_root(root) do
    case File.ls(dir()) do
      {:ok, names} ->
        for name <- names,
            String.ends_with?(name, ".json"),
            {id, ".json"} <- [Integer.parse(name)],
            {:ok, manifest} <- [read_manifest(id)],
            manifest["root"] == root,
            manifest["status"] in ["running", "starting", "completed"],
            do: manifest

      {:error, _} ->
        []
    end
  end

  def startup_stale?(%{"started_at" => started_at}) do
    with {:ok, started, _} <- DateTime.from_iso8601(started_at) do
      DateTime.diff(DateTime.utc_now(), started, :second) > 30
    else
      _ -> true
    end
  end

  def startup_stale?(_), do: true

  def alive?(%{"pid" => pid, "identity" => expected}) do
    identity(pid) == {:ok, expected}
  end

  def alive?(_), do: false

  @doc "Stop a streamed run by its verified OS identity, including its child processes."
  def cancel(%{"pid" => pid} = manifest) when is_integer(pid) and pid > 1 do
    if alive?(manifest) do
      pgid =
        case System.cmd("/bin/ps", ["-o", "pgid=", "-p", Integer.to_string(pid)],
               stderr_to_stdout: true
             ) do
          {value, 0} -> String.trim(value)
          _ -> ""
        end

      targets =
        if pgid == Integer.to_string(pid) do
          ["-#{pid}"]
        else
          descendants(pid) ++ [Integer.to_string(pid)]
        end

      Enum.each(targets, &System.cmd("/bin/kill", ["-TERM", "--", &1], stderr_to_stdout: true))
      Process.sleep(100)

      Enum.each(targets, &System.cmd("/bin/kill", ["-KILL", "--", &1], stderr_to_stdout: true))
    end

    :ok
  end

  def cancel(_), do: :ok

  defp descendants(pid) do
    case System.cmd("/bin/ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        pairs =
          for line <- String.split(output, "\n"),
              [child, parent] <- [String.split(line)],
              {child_id, ""} <- [Integer.parse(child)],
              {parent_id, ""} <- [Integer.parse(parent)],
              do: {child_id, parent_id}

        descendants(pairs, [pid], []) |> Enum.map(&Integer.to_string/1)

      _ ->
        []
    end
  end

  defp descendants(pairs, parents, found) do
    children = for {child, parent} <- pairs, parent in parents, do: child
    if children == [], do: found, else: descendants(pairs, children, children ++ found)
  end

  def protected_pid?(pid, root_dir \\ dir()) when is_integer(pid) do
    case File.ls(root_dir) do
      {:ok, names} ->
        Enum.any?(names, fn name ->
          case Integer.parse(name) do
            {_id, ".json"} ->
              with {:ok, data} <- File.read(Path.join(root_dir, name)),
                   {:ok, manifest} <- Jason.decode(data) do
                manifest["status"] == "running" and alive?(manifest) and
                  (manifest["pid"] == pid or descendant_of?(pid, manifest["pid"]))
              else
                _ -> false
              end

            _ ->
              false
          end
        end)

      {:error, _} ->
        false
    end
  end

  @doc "Read only complete JSONL records after the committed byte cursor."
  def unread(%{"run_id" => id, "offset" => offset}) do
    with {:ok, bytes} <- File.read(stream_path(id)),
         true <- byte_size(bytes) >= offset do
      tail = binary_part(bytes, offset, byte_size(bytes) - offset)
      parts = :binary.split(tail, "\n", [:global])
      complete = Enum.drop(parts, -1)
      consumed = complete |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()

      events =
        Enum.flat_map(complete, fn line ->
          case Jason.decode(line) do
            {:ok, %{} = event} -> [event]
            _ -> []
          end
        end)

      {:ok, events, offset + consumed}
    else
      false -> {:error, :stream_truncated}
      error -> error
    end
  end

  @doc "Read complete records from each shard using persisted per-file byte cursors."
  def stream_events(manifest, cursors \\ nil) do
    base = stream_path(manifest["run_id"])
    cursors = cursors || Map.get(manifest, "offsets", %{})

    paths =
      case Path.wildcard(base <> ".shard-*") do
        [] -> [base]
        shards -> Enum.sort_by(shards, &shard_number/1)
      end

    Enum.reduce(paths, {[], cursors}, fn path, {events, positions} ->
      offset = Map.get(positions, path, if(path == base, do: manifest["offset"] || 0, else: 0))

      case File.read(path) do
        {:ok, bytes} when byte_size(bytes) >= offset ->
          tail = binary_part(bytes, offset, byte_size(bytes) - offset)
          complete = tail |> :binary.split("\n", [:global]) |> Enum.drop(-1)
          consumed = Enum.reduce(complete, 0, fn line, n -> n + byte_size(line) + 1 end)

          decoded =
            Enum.flat_map(complete, fn line ->
              case Jason.decode(line) do
                {:ok, %{} = event} -> [event]
                _ -> []
              end
            end)

          {events ++ decoded, Map.put(positions, path, offset + consumed)}

        _ ->
          {events, positions}
      end
    end)
  end

  defp shard_number(path) do
    case Integer.parse(List.last(String.split(path, ".shard-"))) do
      {number, ""} -> number
      _ -> 0
    end
  end

  def advance(manifest, offsets) when is_map(offsets) do
    manifest = Map.put(manifest, "offsets", offsets)
    write_manifest(manifest)
    manifest
  end

  def advance(manifest, offset) when is_integer(offset) do
    manifest = Map.put(manifest, "offset", offset)
    write_manifest(manifest)
    manifest
  end

  def finish(manifest, status) do
    updated =
      manifest
      |> Map.put("status", status)
      |> Map.put("finished_at", DateTime.utc_now() |> DateTime.to_iso8601())

    write_manifest(updated)
    updated
  end

  def complete(manifest, payloads) do
    updated = manifest |> Map.put("status", "completed") |> Map.put("payloads", payloads)
    write_manifest(updated)
    updated
  end

  def acknowledge(manifest, run_id) do
    ids = [manifest["run_id"] | manifest["tied_run_ids"] || []]
    acknowledged = Enum.uniq([run_id | manifest["acknowledged_run_ids"] || []])

    if Enum.all?(ids, &(&1 in acknowledged)) do
      cleanup(manifest["run_id"])
      :complete
    else
      updated = Map.put(manifest, "acknowledged_run_ids", acknowledged)
      write_manifest(updated)
      {:pending, updated}
    end
  end

  def unacknowledged_payloads(manifest) do
    acknowledged = manifest["acknowledged_run_ids"] || []
    Enum.reject(manifest["payloads"] || [], &(&1["run_id"] in acknowledged))
  end

  def all_events(manifest), do: stream_events(Map.put(manifest, "offset", 0), %{}) |> elem(0)

  def completed_result(manifest) do
    events = all_events(manifest)
    finished = Enum.filter(events, &(&1["event"] == "suite_finished"))
    expected = events |> Enum.map(&(&1["shards"] || 1)) |> Enum.max(fn -> 1 end)
    seen = finished |> Enum.map(&(&1["shard"] || 1)) |> Enum.uniq()

    exit_status = read_exit_status(manifest["run_id"])

    cond do
      length(seen) != expected ->
        {:error, "analyzer exited without a complete suite result"}

      not is_integer(exit_status) ->
        {:error, "analyzer exited without a recorded exit status"}

      true ->
        failures = Enum.filter(events, &(&1["event"] in ["test_failed", "test_invalid"]))

        totals =
          Enum.reduce(
            finished,
            %{"pass" => 0, "fail" => 0, "skip" => 0, "excluded" => 0, "invalid" => 0},
            fn event, acc ->
              Map.new(acc, fn {key, value} -> {key, value + (event[key] || 0)} end)
            end
          )

        tests = Enum.sum(Map.values(totals))

        output =
          case File.read(output_path(manifest["run_id"])) do
            {:ok, value} -> value
            _ -> ""
          end

        diagnostics = Enum.map(failures, &failure(&1, manifest["source"]))

        raw = %{
          "source" => manifest["source"],
          "exit_status" => exit_status,
          "output" => output,
          "stats" => %{"tests" => tests, "failures" => totals["fail"] + totals["invalid"]},
          "diagnostics" => diagnostics
        }

        raw =
          if manifest["source"] == "exunit",
            do:
              Map.put(
                raw,
                "execution_status",
                if(exit_status == 0, do: "success", else: "failure")
              ),
            else: raw

        {:ok, raw}
    end
  end

  defp read_exit_status(id) do
    with {:ok, contents} <- File.read(exit_path(id)),
         {status, ""} <- Integer.parse(String.trim(contents)) do
      status
    else
      _ -> nil
    end
  end

  defp failure(event, "spex"),
    do: %{
      "spex" => event["module"],
      "scenario" => event["name"],
      "file" => event["file"],
      "line" => event["failure_line"] || event["line"],
      "message" => event["message"]
    }

  defp failure(event, _),
    do: %{
      "name" => event["name"],
      "test" => event["name"],
      "file" => event["file"],
      "line" => event["failure_line"] || event["line"],
      "message" => event["message"]
    }

  def live_event(%{"event" => kind} = event)
      when kind in ["test_passed", "test_failed", "test_invalid", "test_skipped", "test_excluded"] do
    Map.merge(Map.take(event, ["file", "line", "name", "duration", "message", "failure_line"]), %{
      "event" => "test",
      "state" => String.replace_prefix(kind, "test_", "")
    })
  end

  def live_event(_), do: nil

  def cleanup(id) do
    File.rm(manifest_path(id))
    File.rm(stream_path(id))
    Enum.each(Path.wildcard(stream_path(id) <> ".shard-*"), &File.rm/1)
    File.rm(output_path(id))
    File.rm(exit_path(id))
    :ok
  end

  defp write_manifest(manifest) do
    path = manifest_path(manifest["run_id"])
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, Jason.encode!(manifest))
    File.rename!(tmp, path)
    :ok
  end

  defp descendant_of?(pid, ancestor), do: descendant_of?(pid, ancestor, 16)

  defp descendant_of?(_pid, _ancestor, 0), do: false

  defp descendant_of?(pid, ancestor, remaining) when is_integer(pid) and pid > 1 do
    case System.cmd("/bin/ps", ["-o", "ppid=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {parent, 0} ->
        case Integer.parse(String.trim(parent)) do
          {^ancestor, ""} -> true
          {next, ""} when next > 1 -> descendant_of?(next, ancestor, remaining - 1)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp descendant_of?(_pid, _ancestor, _remaining), do: false

  defp identity(pid) do
    case System.cmd("/bin/ps", ["-o", "lstart=", "-o", "command=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        value = String.trim(output)
        if value == "", do: {:error, :not_found}, else: {:ok, value}

      _ ->
        {:error, :not_found}
    end
  end
end
