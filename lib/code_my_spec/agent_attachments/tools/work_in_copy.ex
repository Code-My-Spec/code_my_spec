defmodule CodeMySpec.AgentAttachments.Tools.WorkInCopy do
  @moduledoc """
  Main's read, write, edit and bash in an attached working copy. These are the
  agents' own tools, run in that copy with its coder's context, so results,
  spilled output, errors and `mix test` routing match a coder's (issue
  2394520b: same tools, separate transport).
  """
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.AgentAttachments.Tools

  @input_keys [
    :file_path,
    :offset,
    :limit,
    :content,
    :old_string,
    :new_string,
    :replace_all,
    :command,
    :timeout
  ]

  @impl true
  def name, do: "work_in_copy"
  @impl true
  def description do
    "Use read, write, edit or bash in Main's attached working copy: the same tools a coder in " <>
      "that copy has, with the same inputs. read takes file_path (and optional offset/limit); " <>
      "write takes file_path and content; edit takes file_path, old_string, new_string and " <>
      "optional replace_all; bash takes command and optional timeout in ms (default 10000, " <>
      "up to 3600000), and its mix test/mix spex is routed through that copy's analysis " <>
      "service. Relative paths resolve in that copy. Connection loss fails the request " <>
      "without retry, replay or recovery; remote work may continue."
  end

  @impl true
  def params do
    %{
      attachment_id: {:required, :string},
      tool: {:required, {:enum, ~w(read write edit bash)}},
      file_path: :string,
      offset: :integer,
      limit: :integer,
      content: :string,
      old_string: :string,
      new_string: :string,
      replace_all: :boolean,
      command: :string,
      timeout: :integer
    }
  end

  @impl true
  def call(params, context) do
    case script_result(params, context) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      result -> Tools.render(result)
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, scope, agent_id} <- Tools.caller(context, params) do
      input = params |> Map.take(@input_keys) |> Map.reject(fn {_k, v} -> is_nil(v) end)
      AgentAttachments.execute(scope, agent_id, params.attachment_id, params.tool, input)
    end
  end
end
