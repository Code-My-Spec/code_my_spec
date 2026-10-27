defmodule CodeMySpec.CopyTools.Tools do
  @moduledoc """
  Main's read, write, edit and bash, each naming the working copy it runs in.

  Their inputs are the agents' own tools' inputs plus `working_copy_id`; the
  copy's harness runs the real tool (`CmsHarness.CopyTools`).
  """
  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Agents, CodeMySpec.CopyTools, CodeMySpec.Tools]

  alias CodeMySpec.Agents
  alias CodeMySpec.CopyTools
  alias CodeMySpec.Tools

  def all, do: [__MODULE__.Read, __MODULE__.Write, __MODULE__.Edit, __MODULE__.Bash]

  @doc false
  def run(tool, params, context) do
    with {:ok, scope} <- Tools.project_scope(context),
         {:ok, agent_id} <- caller(scope, context) do
      input = params |> Map.delete(:working_copy_id) |> Map.reject(fn {_k, v} -> is_nil(v) end)
      CopyTools.run(scope, agent_id, params.working_copy_id, tool, input)
    end
  end

  @doc false
  def render({:ok, text}) when is_binary(text), do: {:ok, text}
  def render({:ok, value}), do: {:ok, Jason.encode!(value)}
  def render({:error, text}) when is_binary(text), do: {:error, text}

  def render({:error, :main_only}),
    do:
      {:error,
       "Only Main reads, writes and runs commands in another working copy this way. " <>
         "An agent works in its own copy with its own tools."}

  def render({:error, :working_copy_not_found}),
    do: {:error, "No such working copy in this project. list_working_copies shows them."}

  def render({:error, :harness_unreachable}),
    do: {:error, "That working copy's harness is not connected, so nothing ran there."}

  def render({:error, :copy_tools_unsupported}),
    do:
      {:error,
       "That working copy's harness predates these tools; update and restart it, then retry."}

  def render({:error, reason}), do: Tools.error(reason)

  defp caller(scope, context) do
    case context[:agent_id] || Agents.terminal_agent_id(scope, context[:session_id]) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :main_only}
    end
  end

  @doc false
  def describe(what) do
    what <> " Main only: runs in the working copy working_copy_id names, as its coder's tool."
  end
end
