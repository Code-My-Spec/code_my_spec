defmodule CodeMySpec.AgentTasks.Setup.Helpers do
  @moduledoc """
  Shared helpers for setup step modules.
  """

  alias CodeMySpec.AgentTasks.Setup.Context
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Users.Scope

  @doc """
  The app name, for a prompt that has to name modules.

  Prefers the synced `mix.exs`, which is where this is known without a disk, and
  falls back to reading one. On the light harness there is no disk to fall back
  to and the synced record is the only source — reading was not merely empty
  there, it crashed: `Environments.read_file/2` has no clause for a nil
  environment, so `start_task` raised a `FunctionClauseError` for every setup
  step whose prompt names a module. An agent hit exactly that and had to
  reconstruct the prompts by disassembling these modules out of a release.

  Falls back to `"your_app"` so a prompt is still readable when nothing is
  synced yet.
  """
  @spec app_name(Scope.t()) :: String.t()
  def app_name(%Scope{} = scope) do
    from_sync = scope |> Context.load() |> Context.app_name()

    from_sync || extract_app_name(scope.environment) || "your_app"
  end

  @doc """
  Extract the app name from mix.exs via the Environment abstraction.
  Returns the app name string or nil.

  Prefer `app_name/1` where a scope is at hand: it works without a disk.
  """
  @spec extract_app_name(Environment.t() | nil) :: String.t() | nil
  def extract_app_name(env) do
    case read_file(env, "mix.exs") do
      nil ->
        nil

      content ->
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, name] -> name
          _ -> nil
        end
    end
  end

  @doc """
  Read a file through the Environment, returning content or nil.

  Nil environment reads as nil rather than raising. A server with no disk is a
  supported configuration, not a bug to crash on, and every caller here already
  handles "could not read it".
  """
  @spec read_file(Environment.t() | nil, String.t()) :: String.t() | nil
  def read_file(nil, _path), do: nil

  def read_file(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end
end
