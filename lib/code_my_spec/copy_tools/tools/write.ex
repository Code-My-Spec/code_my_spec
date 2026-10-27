defmodule CodeMySpec.CopyTools.Tools.Write do
  @moduledoc "Main's write in a named working copy."
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.CopyTools.Tools

  @impl true
  def name, do: "write"
  @impl true
  def description, do: Tools.describe("Write a file's whole content.")

  @impl true
  def params,
    do: %{
      working_copy_id: {:required, :string},
      file_path: {:required, :string},
      content: {:required, :string}
    }

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context), do: Tools.run("write", params, context)
end
