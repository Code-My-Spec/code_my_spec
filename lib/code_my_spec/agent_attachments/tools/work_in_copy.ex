defmodule CodeMySpec.AgentAttachments.Tools.WorkInCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.AgentAttachments.Tools

  @impl true
  def name, do: "work_in_copy"
  @impl true
  def description do
    "Perform an operation in Main's explicitly selected working-copy attachment. " <>
      "Paths are relative to that copy. read_file/list_directory take path; write_file takes " <>
      "path and content; search takes pattern and optional path; command takes an executable " <>
      "and args (no implicit shell). Results belong to this target, never Main's local directory. " <>
      "Connection loss fails the request without retry, replay or recovery; remote work may continue."
  end

  @impl true
  def params do
    %{
      attachment_id: {:required, :string},
      operation: {:required, {:enum, ~w(read_file list_directory write_file search command)}},
      path: :string,
      content: :string,
      pattern: :string,
      command: :string,
      args: {:list, :string}
    }
  end

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context) do
    with {:ok, scope, agent_id} <- Tools.caller(context, params) do
      payload =
        params
        |> Map.take([:path, :content, :pattern, :command, :args])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      case AgentAttachments.execute(
             scope,
             agent_id,
             params.attachment_id,
             params.operation,
             payload
           ) do
        :ok -> {:ok, %{"ok" => true}}
        result -> result
      end
    end
  end
end
