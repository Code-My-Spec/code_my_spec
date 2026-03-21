defmodule CodeMySpecLocalWeb.SetupMarkdown do
  @moduledoc """
  Markdown rendering for the setup API (LLM interface).
  """

  defdelegate index(assigns), to: CodeMySpecLocalWeb.InitMarkdown
  defdelegate show(assigns), to: CodeMySpecLocalWeb.InitMarkdown
end
