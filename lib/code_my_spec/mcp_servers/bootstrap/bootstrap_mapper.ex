defmodule CodeMySpec.McpServers.Bootstrap.BootstrapMapper do
  @moduledoc """
  Maps bootstrap tool results to MCP responses.
  """

  alias Anubis.Server.Response

  def install_success(path) do
    Response.tool()
    |> Response.text("Installed: #{path}")
    |> Map.put(:structured_content, %{status: :ok, path: path})
  end

  def install_success(path, extras) do
    data = Map.merge(%{status: :ok, path: path}, extras)

    Response.tool()
    |> Response.text("Installed: #{path}")
    |> Map.put(:structured_content, data)
  end

  def init_success(config_path, project_name) do
    data = %{status: :ok, config_path: config_path, project_name: project_name}

    Response.tool()
    |> Response.text("Project initialized: #{project_name}\nConfig: #{config_path}")
    |> Map.put(:structured_content, data)
  end

  def status_response(text, data) do
    Response.tool()
    |> Response.text(text)
    |> Map.put(:structured_content, data)
  end

  def error(reason) when is_binary(reason) do
    Response.tool()
    |> Response.error(reason)
  end

  def error(reason), do: error(inspect(reason))
end
