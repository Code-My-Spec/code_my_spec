defmodule CodeMySpec.BddSpecs.Types.AtomArray do
  @moduledoc """
  Custom Ecto type for arrays of atoms.
  Stores atoms as strings in the database and converts them back to atoms when loading.
  """

  use Ecto.Type

  @spec type() :: :map
  def type, do: :map

  @spec cast(term()) :: {:ok, list(atom())} | :error
  def cast(atoms) when is_list(atoms) do
    if Enum.all?(atoms, &is_atom/1) do
      {:ok, atoms}
    else
      :error
    end
  end

  def cast(_), do: :error

  @spec load(term()) :: {:ok, list(atom())} | :error
  def load(strings) when is_list(strings) do
    atoms = Enum.map(strings, &String.to_atom/1)
    {:ok, atoms}
  end

  def load(_), do: :error

  @spec dump(term()) :: {:ok, list(String.t())} | :error
  def dump(atoms) when is_list(atoms) do
    if Enum.all?(atoms, &is_atom/1) do
      strings = Enum.map(atoms, &Atom.to_string/1)
      {:ok, strings}
    else
      :error
    end
  end

  def dump(_), do: :error
end
