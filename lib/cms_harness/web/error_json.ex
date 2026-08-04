defmodule CmsHarness.Web.ErrorJSON do
  @moduledoc """
  What a hook sees when the harness itself fell over.

  It names the harness, because the caller is a `curl` inside an agent turn and
  whoever reads the output has to know which process to go and look at. A bare
  `{"errors":{"detail":"Internal Server Error"}}` reads as the server being
  down, which is the misdiagnosis this whole surface is written to avoid.
  """

  def render(template, _assigns) do
    %{
      "systemMessage" =>
        "The CodeMySpec harness failed to handle this hook (#{Phoenix.Controller.status_message_from_template(template)}). " <>
          "This is the local harness process, not the CodeMySpec server. Check its log."
    }
  end
end
