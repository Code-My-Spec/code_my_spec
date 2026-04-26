defmodule CodeMySpec.Tests.TestResult do
  @moduledoc false
  alias CodeMySpec.Tests.TestError
  use Ecto.Schema

  @derive Jason.Encoder
  @type result_status :: :passed | :failed
  @type t :: %__MODULE__{
          title: String.t(),
          full_title: String.t(),
          status: result_status(),
          error: TestError.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :title, :string
    field :full_title, :string
    field :status, Ecto.Enum, values: [:passed, :failed]
    embeds_one :error, TestError
  end

  def changeset(test_result \\ %__MODULE__{}, attrs) do
    test_result
    |> Ecto.Changeset.cast(attrs, [:title, :full_title, :status])
    |> Ecto.Changeset.cast_embed(:error, with: &TestError.changeset/2)
  end
end
