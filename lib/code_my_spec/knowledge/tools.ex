defmodule CodeMySpec.Knowledge.Tools do
  @moduledoc "The knowledge tools agents call, independent of the MCP surface."

  alias CodeMySpec.Tools

  def all, do: [__MODULE__.ListKnowledge, __MODULE__.ReadKnowledge]

  def library(%{library: nil}), do: {:ok, :knowledge}
  def library(%{library: "knowledge"}), do: {:ok, :knowledge}
  def library(%{library: "project_knowledge"}), do: {:ok, :project_knowledge}
  def library(%{library: other}), do: {:error, {:invalid_library, other}}
  def library(_params), do: {:ok, :knowledge}

  def path(%{path: path}) when is_binary(path) and path != "",
    do: String.split(path, "/", trim: true)

  def path(_params), do: []

  def error({:invalid_library, value}),
    do: {:error, "Invalid library #{inspect(value)}. Use 'knowledge' or 'project_knowledge'."}

  def error(:not_found), do: {:error, "Path not found"}
  def error(:invalid_path), do: {:error, "Invalid path"}
  def error(:missing_active_project), do: Tools.error(:missing_active_project)
  def error(reason), do: {:error, inspect(reason)}
end
