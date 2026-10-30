defmodule CodeMySpec.CopyTools do
  @moduledoc """
  Main's read, write, edit and bash in a working copy it names on each call.

  Main has no working copy of its own (issue e377de11). Each call names one by
  id, is authorized on its own (the caller is Main, the copy is in Main's
  project), and travels over that copy's harness channel, where the copy's
  harness runs the agents' own tool with that copy's coder context: same
  tools, separate transport. No connection state, no retries, no replay.
  """
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents.Agent,
      CodeMySpec.Analysis.HarnessRegistry,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.CopyTools.Transport
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @tools ~w(read write edit bash)
  # Bash owns a deadline of up to an hour, as an agent's does; the request
  # outlives it so the tool, not the wire, reports a timeout.
  @timeout :timer.hours(1) + 15_000

  @doc "The tool names Main runs in a copy."
  def tools, do: @tools

  @doc "Run `tool` with that tool's own `input` in the working copy `copy_id`."
  def run(scope, agent_id, copy_id, tool, input) when tool in @tools and is_map(input) do
    with {:ok, _agent} <- main(scope, agent_id),
         {:ok, copy} <- copy(scope, copy_id) do
      payload = %{
        "working_copy_id" => copy.id,
        "tool" => tool,
        "input" => Map.new(input, fn {key, value} -> {to_string(key), value} end)
      }

      transport().request(copy.id, "copy_tool", payload, @timeout)
    end
  end

  def run(_scope, _agent_id, _copy_id, tool, _input) when tool in @tools,
    do: {:error, :invalid_payload}

  def run(_scope, _agent_id, _copy_id, _tool, _input), do: {:error, :unsupported_tool}

  @doc "Whether this agent is the project's Main, the only caller these tools serve."
  def main(%Scope{active_project_id: project, active_account_id: account}, id)
      when is_binary(project) and is_binary(account) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Agent{role: :main, retired_at: nil, off_at: nil} = agent <-
           Repo.get_by(Agent, id: uuid, project_id: project, account_id: account) do
      {:ok, agent}
    else
      _ -> {:error, :main_only}
    end
  end

  def main(_scope, _id), do: {:error, :main_only}

  defp copy(%Scope{active_project_id: project}, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, %{project_id: ^project, root: root} = copy} when is_binary(root) and root != "" <-
           WorkingCopies.fetch(uuid) do
      {:ok, copy}
    else
      _ -> {:error, :working_copy_not_found}
    end
  end

  defp transport, do: Application.get_env(:code_my_spec, :copy_tools_transport, Transport)
end
