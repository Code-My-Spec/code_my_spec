defmodule CodeMySpecWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use CodeMySpecWeb, :html

  embed_templates "error_html/*"

  # Any status without a dedicated template still renders plain text,
  # e.g. "500.html" becomes "Internal Server Error".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
