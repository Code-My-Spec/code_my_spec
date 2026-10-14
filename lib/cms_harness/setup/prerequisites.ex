defmodule CmsHarness.Setup.Prerequisites do
  @moduledoc "Machine prerequisite commands and interpretation of their results."

  alias CmsHarness.Setup.{Command, Step}

  @keys ~w(postgres pgvector version_manager erlang elixir cms vibium)

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec run(Step.t(), String.t()) :: Step.t()
  def run(%Step{key: key, state: :running} = step, cwd) when key in @keys do
    {command, args} = command(key)
    result = Command.run(cwd, command, args)

    step
    |> Step.record_command(result)
    |> Step.finish(outcome(key, result), DateTime.utc_now())
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
  defp command("cms"), do: {"cms", ["--version"]}
  defp command("vibium"), do: {"vibium", ["--version"]}

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
