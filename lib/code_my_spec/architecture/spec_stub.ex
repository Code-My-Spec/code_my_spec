defmodule CodeMySpec.Architecture.SpecStub do
  @moduledoc """
  Where a component's spec file conventionally lives.

  Components are records now (3aeb66cf); nothing writes stubs. Deleting a
  component still removes a spec left at this path.
  """

  alias CodeMySpec.Paths

  @doc """
  Returns the conventional spec file path for a component module name.

      iex> CodeMySpec.Architecture.SpecStub.path_for("MyApp.Accounts")
      ".code_my_spec/spec/my_app/accounts.spec.md"
  """
  @spec path_for(String.t()) :: String.t()
  def path_for(module_name) do
    path_parts =
      module_name
      |> String.trim()
      |> String.split(".")
      |> Enum.map(&(&1 |> String.trim() |> Macro.underscore()))

    Path.join([Paths.spec_dir() | path_parts]) <> ".spec.md"
  end
end
