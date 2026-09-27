defmodule CmsHarness.SopsKeyring do
  @moduledoc """
  The machine's sops age keyring, kept holding the keys for the projects this
  harness serves.

  A working copy's dev and test secrets are committed as `envs/*.enc.env`, and
  `just init-worktree` decrypts them into the new copy. That only works on a
  machine whose keyring holds the project's key, so the server hands the keys
  over on join (`age_private_key_dev`, `age_private_key_test` — never a deploy
  environment's) and they are appended here.

  The keyring is the file sops itself reads — see `path/0`.
  """

  require Logger

  @doc """
  Append each key the keyring does not already hold. Answers how many were added.
  """
  @spec install([String.t()], Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def install(keys, path \\ path())

  def install([], _path), do: {:ok, 0}

  def install(keys, path) when is_list(keys) do
    held = held(path)
    new = keys |> Enum.filter(&valid?/1) |> Enum.uniq() |> Enum.reject(&MapSet.member?(held, &1))

    with :ok <- append(path, new) do
      if new != [], do: Logger.info("[CmsHarness] added #{length(new)} age key(s) to #{path}")
      {:ok, length(new)}
    end
  end

  @doc """
  The keyring sops reads, in sops' own order. `~/.config` is only the default
  off macOS: there sops uses the OS config directory, so a key written to
  `~/.config` was never found.
  """
  @spec path() :: Path.t()
  def path do
    System.get_env("SOPS_AGE_KEY_FILE") ||
      Path.join([config_dir(), "sops", "age", "keys.txt"])
  end

  defp config_dir do
    case {System.get_env("XDG_CONFIG_HOME"), :os.type()} do
      {xdg, _} when is_binary(xdg) and xdg != "" -> xdg
      {_, {:unix, :darwin}} -> Path.join([System.user_home!(), "Library", "Application Support"])
      _ -> Path.join(System.user_home!(), ".config")
    end
  end

  defp valid?(key), do: is_binary(key) and String.starts_with?(key, "AGE-SECRET-KEY-")

  defp held(path) do
    case File.read(path) do
      {:ok, body} ->
        body |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  defp append(_path, []), do: :ok

  defp append(path, keys) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, separator(path) <> Enum.join(keys, "\n") <> "\n", [:append]) do
      File.chmod(path, 0o600)
    end
  end

  # A keyring edited by hand may not end in a newline, and a key glued onto the
  # previous line is one sops cannot parse.
  defp separator(path) do
    case File.read(path) do
      {:ok, ""} -> ""
      {:ok, body} -> if String.ends_with?(body, "\n"), do: "", else: "\n"
      {:error, _} -> ""
    end
  end
end
