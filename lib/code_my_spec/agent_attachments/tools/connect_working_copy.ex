defmodule CodeMySpec.AgentAttachments.Tools.ConnectWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.AgentAttachments.Tools

  @impl true
  def name, do: "connect_working_copy"
  @impl true
  def description do
    "Connect Main to an authorized working copy by its ID from list_working_copies. " <>
      "Returns an attachment ID for work_in_copy. Multiple attachments coexist without " <>
      "moving or restarting Main or displacing Coding/QA. An offline target is a hard error."
  end

  @impl true
  def params do
    %{
      working_copy_id: {:required, :string}
    }
  end

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context) do
    with {:ok, scope, agent_id} <- Tools.caller(context, params),
         {:ok, attachment} <- AgentAttachments.connect(scope, agent_id, params.working_copy_id) do
      {:ok, Tools.row(attachment)}
    end
  end
end
