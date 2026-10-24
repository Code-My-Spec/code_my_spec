defmodule CodeMySpec.AgentAttachments.Tools.ListWorkingCopyAttachments do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.AgentAttachments.Tools

  @impl true
  def name, do: "list_working_copy_attachments"
  @impl true
  def description,
    do:
      "List Main's working-copy attachment IDs and target copy IDs. Attachments do not change Main's runtime location."

  @impl true
  def params,
    do: %{}

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context) do
    with {:ok, scope, agent_id} <- Tools.caller(context, params) do
      case AgentAttachments.list(scope, agent_id) do
        rows when is_list(rows) -> {:ok, Enum.map(rows, &Tools.row/1)}
        error -> error
      end
    end
  end
end
