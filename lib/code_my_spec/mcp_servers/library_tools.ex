defmodule CodeMySpec.McpServers.LibraryTools do
  @moduledoc """
  Domain tools (`CodeMySpec.ToolLibrary`) on an Anubis server's direct list.

  `register/2` runs in the server's `init/2` and puts each tool on the
  session's frame with `Frame.register_tool/3`. Anubis then lists them beside
  the compiled components, validates their arguments with the same Peri schema
  code mode uses, and hands a call to the server's `handle_tool_call/3`, which
  passes it to `call/4`.

  See knowledge/tools, "Tool library".
  """

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators

  @doc "Registers each tool on the frame."
  @spec register(Frame.t(), [module()]) :: Frame.t()
  def register(frame, tools) do
    Enum.reduce(tools, frame, fn tool, frame ->
      Frame.register_tool(frame, tool.name(),
        description: tool.description(),
        input_schema: tool.params()
      )
    end)
  end

  @doc "Runs the named tool with arguments Anubis has already validated."
  @spec call([module()], String.t(), map(), Frame.t()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def call(tools, name, params, frame) do
    case Enum.find(tools, &(&1.name() == name)) do
      nil ->
        {:error, Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"}), frame}

      tool ->
        {:reply, run(tool, params, frame), frame}
    end
  end

  # The scope a compiled tool would get: from the request, or the configured
  # project when the request named none (`Validators.validate_local_scope/1`).
  defp run(tool, params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> response(tool.call(params, context(scope, params, frame)))
      {:error, reason} -> response({:error, unscoped(reason)})
    end
  end

  defp unscoped(:no_working_dir) do
    "This tool needs the project's working copy, and this request did not name one. " <>
      "The MCP client must send an `X-Harness-Id` header; the id is in .cms_harness.json " <>
      "at the working copy's root, written by `mix cms.harness.onboard`."
  end

  defp unscoped(reason), do: "This request has no project scope: #{inspect(reason)}"

  # `session_id` arrives in the arguments (the PreToolUse hook injects it);
  # an agent we run is named on the connection.
  defp context(scope, params, frame) do
    %{scope: scope}
    |> put_known(:session_id, params[:session_id])
    |> put_known(:agent_id, frame.assigns[:agent_id])
    |> put_known(:working_dir, frame.assigns[:working_dir])
  end

  defp put_known(context, _key, nil), do: context
  defp put_known(context, key, value), do: Map.put(context, key, value)

  defp response({:ok, text}), do: Response.tool() |> Response.text(text)
  defp response({:error, text}), do: Response.tool() |> Response.error(text)
end
