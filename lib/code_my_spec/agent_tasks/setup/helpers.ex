defmodule CodeMySpec.AgentTasks.Setup.Helpers do
  @moduledoc """
  Shared helpers for setup step modules.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @doc """
  Extract the app name from mix.exs via the Environment abstraction.
  Returns the app name string or nil.
  """
  @spec extract_app_name(Environment.t()) :: String.t() | nil
  def extract_app_name(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Read a file through the Environment, returning content or nil.
  """
  @spec read_file(Environment.t(), String.t()) :: String.t() | nil
  def read_file(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end
end
