defmodule CmsHarness.DiskCapacity do
  @moduledoc """
  Free-space preflight for work that writes to a checkout or temporary directory.
  The reader can be injected for tests without filling a disk.
  """

  @minimum_bytes 512 * 1024 * 1024

  def check(paths),
    do:
      check(
        paths,
        Application.get_env(:code_my_spec, :harness_disk_capacity_reader, &free_bytes/1)
      )

  @spec check([String.t()], (String.t() -> {:ok, non_neg_integer()} | {:error, term()})) ::
          :ok | {:error, String.t()}
  def check(paths, reader) do
    paths
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, free} ->
      case reader.(path) do
        {:ok, bytes} when is_integer(bytes) and bytes >= 0 ->
          {:cont, {:ok, [bytes | free]}}

        other ->
          {:halt, {:error, "could not check disk space for #{path}: #{inspect(other)}"}}
      end
    end)
    |> verdict()
  end

  defp verdict({:error, _} = error), do: error
  defp verdict({:ok, []}), do: :ok

  defp verdict({:ok, bytes}) do
    free = Enum.min(bytes)

    if free < @minimum_bytes,
      do: {:error, "disk nearly full: #{div(free, 1024 * 1024)} MiB free"},
      else: :ok
  end

  @spec free_bytes(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def free_bytes(path) do
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} ->
        fields = output |> String.trim() |> String.split("\n") |> List.last() |> String.split()

        case Enum.at(fields, 3) do
          nil ->
            {:error, "unreadable df output"}

          available ->
            case Integer.parse(available) do
              {blocks, ""} when blocks >= 0 -> {:ok, blocks * 1024}
              _ -> {:error, "unreadable df output"}
            end
        end

      {output, _status} ->
        {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
