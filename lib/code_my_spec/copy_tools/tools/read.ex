defmodule CodeMySpec.CopyTools.Tools.Read do
  @moduledoc "Main's read in a named working copy."
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.CopyTools.Tools

  @impl true
  def name, do: "read"
  @impl true
  def description,
    do: Tools.describe("Read a file, optionally by offset and limit.")

  @impl true
  def params,
    do: %{
      working_copy_id: {:required, :string},
      file_path: {:required, :string},
      offset: :integer,
      limit: :integer
    }

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context), do: Tools.run("read", params, context)
end
