defmodule CodeMySpec.Tests.TestError do
  @moduledoc false
  use Ecto.Schema

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          message: String.t()
        }

  @primary_key false
  embedded_schema do
    field :file, :string
    field :line, :integer
    field :message, :string
  end

  def changeset(test_error \\ %__MODULE__{}, attrs) do
    test_error
    |> Ecto.Changeset.cast(attrs, [:file, :line, :message])
  end
end
