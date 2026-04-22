defmodule CodeMySpec.AgentTasks.Init.PhoenixInstaller do
  @moduledoc """
  Init step: verify Phoenix installer (phx_new) is available.

  Reads the mix archives directory directly instead of shelling out to
  `mix archive` — shelling out from inside a mix project loads that
  project's config, which can fail for unrelated reasons (missing
  env-specific config files, bad deps, etc.).
  """

  def evaluate(_scope, _task) do
    archives_dir = mix_archives_dir()

    case File.ls(archives_dir) do
      {:ok, entries} ->
        if Enum.any?(entries, &String.starts_with?(&1, "phx_new-")),
          do: {:ok, :valid},
          else: {:ok, :invalid, "phx_new archive not installed"}

      {:error, :enoent} ->
        {:ok, :invalid,
         "No mix archives directory at #{archives_dir}. Install Elixir, then `mix archive.install hex phx_new`."}

      {:error, reason} ->
        {:ok, :invalid,
         "Could not read #{archives_dir}: #{inspect(reason)}"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Install Phoenix Installer

    ```bash
    mix archive.install hex phx_new
    ```

    Verify: `mix archive | grep phx_new`
    """}
  end

  defp mix_archives_dir do
    cond do
      dir = System.get_env("MIX_ARCHIVES") -> dir
      mix_home = System.get_env("MIX_HOME") -> Path.join(mix_home, "archives")
      true -> Path.expand("~/.mix/archives")
    end
  end
end
