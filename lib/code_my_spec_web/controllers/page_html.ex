defmodule CodeMySpecWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use CodeMySpecWeb, :html

  embed_templates "page_html/*"

  @external_resource code_my_spec_copy_path =
                       Path.join(__DIR__, "page_html/code_my_spec_copy.exs")
  @code_my_spec_copy (case Code.eval_file(code_my_spec_copy_path) do
                        {copy, _} -> copy
                      end)

  def code_my_spec_copy, do: @code_my_spec_copy

end
