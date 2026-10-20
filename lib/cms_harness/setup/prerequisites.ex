defmodule CmsHarness.Setup.Prerequisites do
  @moduledoc "Machine prerequisite commands and interpretation of their results."

  alias CmsHarness.Setup.{Command, Platform, Step}

  @keys ~w(postgres pgvector version_manager erlang elixir cms vibium)

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  Runs the check for `step`'s key, in `cwd`.

  With a `platform`, `install_command/2` runs first whenever one exists for
  this key -- unconditionally, the way `brew install` or `winget install` are
  themselves idempotent, rather than only after the check has already found
  the prerequisite missing. No `platform` (the default) is today's
  check-only behavior, unchanged -- this is what every machine that is not
  Windows or an ARM Mac still gets, and what every spec that never names a
  platform keeps getting.
  """
  @spec run(Step.t(), String.t(), Platform.t() | nil) :: Step.t()
  def run(step, cwd, platform \\ nil)

  def run(%Step{key: key, state: :running} = step, cwd, platform) when key in @keys do
    step = maybe_install(step, key, cwd, platform)
    {command, args} = command(key)
    result = Command.run(cwd, command, args)
    step = Step.record_command(step, result)
    Step.finish(step, outcome(key, result), DateTime.utc_now())
  end

  defp maybe_install(step, key, cwd, platform) do
    case install_command(key, platform) do
      nil ->
        step

      {install_cmd, install_args} ->
        Step.record_command(step, Command.run(cwd, install_cmd, install_args))
    end
  end

  defp command("postgres"), do: {"psql", ["--version"]}

  defp command("pgvector") do
    {"psql",
     [
       "-X",
       "--no-password",
       "--dbname=postgres",
       "-v",
       "ON_ERROR_STOP=1",
       "-At",
       "-c",
       "SELECT name, default_version FROM pg_available_extensions WHERE name = 'vector'"
     ]}
  end

  defp command("version_manager") do
    case System.find_executable("mise") do
      nil -> {"asdf", ["current"]}
      _path -> {"mise", ["current"]}
    end
  end

  defp command("erlang") do
    {"erl",
     [
       "-noshell",
       "-eval",
       "io:format(" <> inspect("~s~n") <> ", [erlang:system_info(otp_release)]), halt()."
     ]}
  end

  defp command("elixir"), do: {"elixir", ["--version"]}
  defp command("cms"), do: {"cms", ["version"]}
  defp command("vibium"), do: {"vibium", ["--version"]}

  # What (if anything) makes `key` ready on `platform`. On Windows, `mise`
  # installs the Elixir toolchain (the `version_manager` step itself, and
  # `elixir` which that leaves ready); Erlang has no such convention there
  # (its own release is a native installer) and gets one of its own. An ARM
  # Mac has every prerequisite as a normal Homebrew formula, just run under
  # the arm64 slice explicitly rather than assumed from the shell that
  # launched the harness.
  defp install_command(_key, nil), do: nil

  defp install_command("version_manager", %Platform{os: :windows}), do: {"mise", ["install"]}

  defp install_command("erlang", %Platform{os: :windows}),
    do: {"winget", ["install", "--id", "Erlang-Solutions.Erlang", "-e"]}

  defp install_command(key, %Platform{os: :windows}) when key in ~w(postgres pgvector),
    do: {"winget", ["install", "--id", "PostgreSQL.PostgreSQL", "-e"]}

  defp install_command(_key, %Platform{os: :windows}), do: nil

  defp install_command(key, %Platform{os: :darwin, arch: :aarch64})
       when key in ~w(postgres pgvector version_manager erlang elixir),
       do: {"arch", ["-arm64", "brew", "install", homebrew_formula(key)]}

  defp install_command(_key, _platform), do: nil

  defp homebrew_formula("version_manager"), do: "mise"
  defp homebrew_formula(key), do: key

  defp outcome(key, %{exit_status: 0, error: nil, output: output}),
    do: interpret(key, output)

  defp outcome(_key, %{error: error, output: output}) when is_binary(error) do
    {:error, String.trim(error <> "\n" <> output)}
  end

  defp interpret("pgvector", output) do
    case Regex.match?(~r/^vector\|[^\s]+/m, output) do
      true -> :ok
      false -> {:error, "pgvector is not installed in this Postgres installation"}
    end
  end

  defp interpret("version_manager", output) do
    case {Regex.match?(~r/^\s*erlang\s+\d/m, output), Regex.match?(~r/^\s*elixir\s+\d/m, output)} do
      {true, true} -> :ok
      _ -> {:error, "Configure Erlang and Elixir with mise or asdf before continuing"}
    end
  end

  defp interpret(_key, output) do
    case String.trim(output) do
      "" -> {:error, "The prerequisite command returned no version information"}
      _version -> :ok
    end
  end
end
