defmodule CodeMySpec.CopyTools.Tools.Bash do
  @moduledoc "Main's bash in a named working copy."
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.CopyTools.Tools

  @impl true
  def name, do: "bash"
  @impl true
  def description,
    do:
      Tools.describe(
        "Run a restricted shell command; timeout in ms (default 10000, max 3600000)."
      )

  @impl true
  def params,
    do: %{
      working_copy_id: {:required, :string},
      command: {:required, :string},
      timeout: :integer
    }

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context), do: Tools.run("bash", params, context)
end
