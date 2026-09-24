defmodule CmsHarness.ServedRoots do
  @moduledoc """
  Restart hints for working copies this harness explicitly served.

  The server still owns the roster and each checkout owns its identity and
  credentials. These files only break the boot cycle: without one known root,
  a per-copy-key install cannot authenticate its device announce to retrieve
  the server's roster. No credentials are copied here.
  """

  alias CmsHarness.{Config, Credentials, HarnessConfig, ProjectIdentity}
  require Logger

  def remember(root) do
    with {:ok, config} <- HarnessConfig.read_file(root),
         true <- matching_server?(config.server_url) do
      entry = %{
        root: Path.expand(root),
        working_copy_id: config.working_copy_id,
        project_id: config.project_id,
        server_url: server()
      }

      path = entry_path(root)
      temporary = path <> ".#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

      result =
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(temporary, Jason.encode!(entry)),
             :ok <- File.chmod(temporary, 0o600) do
          File.rename(temporary, path)
        end

      File.rm(temporary)
      report(result)
    else
      _ -> :ok
    end
  end

  def forget(root) do
    case File.rm(entry_path(root)) do
      {:error, :enoent} -> :ok
      result -> report(result)
    end
  end

  def list do
    directory()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&restorable/1)
    |> Enum.uniq()
  end

  defp restorable(path) do
    with {:ok, contents} <- File.read(path),
         {:ok,
          %{"root" => root, "working_copy_id" => id, "project_id" => project, "server_url" => url}} <-
           Jason.decode(contents),
         true <- is_binary(root) and File.dir?(root) and url == server(),
         {:ok, config} <- HarnessConfig.read_file(root),
         true <- config.working_copy_id == id and config.project_id == project,
         true <- matching_server?(config.server_url),
         {:ok, resolved} <- ProjectIdentity.resolve(root),
         true <- resolved.id == project and resolved.working_copy_id == id,
         {:ok, _credential, _source} <- Credentials.for_working_copy(root) do
      [root]
    else
      _ -> []
    end
  end

  defp directory do
    base =
      Application.get_env(:code_my_spec, :harness_served_roots_dir) ||
        Path.join(Config.local_state_dir(), "served_roots")

    Path.join(base, digest(server()))
  end

  defp entry_path(root), do: Path.join(directory(), digest(Path.expand(root)) <> ".json")
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp server, do: String.trim_trailing(Config.server_url(), "/")
  defp matching_server?(nil), do: true
  defp matching_server?(url) when is_binary(url), do: String.trim_trailing(url, "/") == server()

  defp matching_server?(_url), do: false

  defp report(:ok), do: :ok

  defp report({:error, reason}) do
    Logger.warning("[CmsHarness] could not persist served roots: #{inspect(reason)}")
    :ok
  end
end
