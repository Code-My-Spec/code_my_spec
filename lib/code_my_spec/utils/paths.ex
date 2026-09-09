defmodule CodeMySpec.Utils.Paths do
  @moduledoc """
  Utilities for resolving and working with file system paths within the project,
  particularly for determining context paths.
  """

  @doc """
  Converts a module name to a file system path.

  ## Examples

      iex> module_to_path("MyApp.Accounts.User")
      "my_app/accounts/user"

      iex> module_to_path("MyApp.Accounts")
      "my_app/accounts"
  """
  @spec module_to_path(String.t()) :: String.t()
  def module_to_path(module_name) when is_binary(module_name) do
    module_name
    |> String.replace_prefix("", "")
    |> Macro.underscore()
    |> String.replace(".", "/")
    |> String.downcase()
  end
end
