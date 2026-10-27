defmodule CodeMySpec.CopyTools.Tools.Edit do
  @moduledoc "Main's edit in a named working copy."
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.CopyTools.Tools

  @impl true
  def name, do: "edit"
  @impl true
  def description,
    do: Tools.describe("Replace old_string with new_string in a file.")

  @impl true
  def params,
    do: %{
      working_copy_id: {:required, :string},
      file_path: {:required, :string},
      old_string: {:required, :string},
      new_string: {:required, :string},
      replace_all: :boolean
    }

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context), do: Tools.run("edit", params, context)
end
