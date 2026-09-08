defmodule CodeMySpec.Utils.ModuleType do
  @moduledoc """
  A reusable utility for creating Ecto custom types that represent a set of valid modules.
  """

  @doc """
  Defines a custom Ecto type for a list of valid modules.

  ## Usage

      defmodule MyApp.CustomType do
        use CodeMySpec.Utils.ModuleType,
          valid_types: [
            MyApp.TypeOne,
            MyApp.TypeTwo
          ]
      end
  """
  defmacro __using__(opts) do
    valid_types = Keyword.fetch!(opts, :valid_types)

    quote do
      use Ecto.Type

      @valid_types unquote(valid_types)

      @type t :: module()

      @spec type() :: :string
      def type, do: :string

      @spec cast(binary() | atom()) :: {:ok, t()} | :error
      def cast(module) when is_atom(module) and module in @valid_types do
        {:ok, module}
      end

      def cast(string) when is_binary(string) do
        case Map.get(mapper(), string) do
          nil -> :error
          module -> cast(module)
        end
      end

      def cast(_), do: :error

      @spec load(binary()) :: {:ok, t()} | :error
      def load(data) when is_binary(data), do: {:ok, String.to_existing_atom(data)}

      @spec dump(atom()) :: {:ok, binary()} | :error
      def dump(module) when is_atom(module) and module in @valid_types do
        {:ok, Atom.to_string(module)}
      end

      def dump(_), do: :error

      @spec mapper() :: %{String.t() => module()}
      def mapper do
        Map.new(@valid_types, fn type ->
          {type |> Atom.to_string() |> String.split(".") |> List.last(), type}
        end)
      end

      @spec valid_types() :: [module()]
      def valid_types, do: @valid_types
    end
  end
end
