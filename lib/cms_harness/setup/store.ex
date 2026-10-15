defmodule CmsHarness.Setup.Store do
  @moduledoc "Machine-local setup snapshots; reading history never runs prerequisites."

  alias CmsHarness.Config

  @spec directory() :: String.t()
  def directory, do: Path.join(Config.local_state_dir(), "setup")

  @spec results_path(String.t(), String.t()) :: String.t()
  def results_path(directory, run_id) do
    validate_run_id!(run_id)
    Path.join([directory, "runs", run_id <> ".json"])
  end

  @spec load(String.t()) :: {:ok, map()} | :none | {:error, term()}
  def load(directory) when is_binary(directory) do
    case File.read(Path.join(directory, "current.json")) do
      {:ok, contents} -> load_pointer(directory, Jason.decode(contents))
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @spec save(String.t(), map()) :: :ok | {:error, term()}
  def save(directory, %{"version" => 1, "run_id" => run_id} = snapshot) do
    path = results_path(directory, run_id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_write(path, Jason.encode!(snapshot, pretty: true)) do
      atomic_write(
        Path.join(directory, "current.json"),
        Jason.encode!(%{"version" => 1, "run_id" => run_id})
      )
    end
  end

  defp load_pointer(directory, {:ok, %{"version" => 1, "run_id" => run_id}})
       when is_binary(run_id) do
    case valid_run_id?(run_id) do
      true -> read_snapshot(directory, run_id)
      false -> {:error, :invalid_setup_pointer}
    end
  end

  defp load_pointer(_directory, _decoded), do: {:error, :invalid_setup_pointer}

  defp read_snapshot(directory, run_id) do
    with {:ok, contents} <- File.read(results_path(directory, run_id)),
         {:ok, snapshot} <- Jason.decode(contents) do
      validate_snapshot(snapshot, run_id)
    end
  end

  defp validate_snapshot(
         %{"version" => 1, "run_id" => run_id, "steps" => steps} = snapshot,
         run_id
       )
       when is_list(steps), do: {:ok, snapshot}

  defp validate_snapshot(_snapshot, _run_id), do: {:error, :invalid_setup_snapshot}

  defp atomic_write(path, contents) do
    temporary =
      path <> "." <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> ".tmp"

    try do
      with :ok <- File.write(temporary, contents, [:binary, :exclusive, :sync]) do
        File.rename(temporary, path)
      end
    after
      File.rm(temporary)
    end
  end

  defp validate_run_id!(run_id) do
    case valid_run_id?(run_id) do
      true -> :ok
      false -> raise ArgumentError, "setup run id must be 32 lowercase hexadecimal characters"
    end
  end

  defp valid_run_id?(run_id) when is_binary(run_id),
    do: Regex.match?(~r/\A[0-9a-f]{32}\z/, run_id)

  defp valid_run_id?(_run_id), do: false
end
