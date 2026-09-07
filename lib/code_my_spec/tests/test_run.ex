defmodule CodeMySpec.Tests.TestRun do
  @moduledoc """
  Embedded schema representing a complete test execution run with metadata,
  statistics, and test results.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Tests.TestResult
  alias CodeMySpec.Tests.TestStats

  @derive Jason.Encoder

  @type execution_status :: :success | :failure | :timeout | :error
  @type t :: %__MODULE__{
          file_path: String.t() | nil,
          command: String.t() | nil,
          exit_code: non_neg_integer() | nil,
          execution_status: execution_status() | nil,
          seed: non_neg_integer() | nil,
          including: [String.t()],
          excluding: [String.t()],
          stats: TestStats.t() | nil,
          tests: [TestResult.t()],
          failures: [TestResult.t()],
          pending: [TestResult.t()],
          raw_output: String.t() | nil,
          ran_at: DateTime.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :file_path, :string
    field :command, :string
    field :exit_code, :integer
    field :execution_status, Ecto.Enum, values: [:success, :failure, :timeout, :error]
    field :seed, :integer
    field :including, {:array, :string}, default: []
    field :excluding, {:array, :string}, default: []
    field :raw_output, :string
    field :ran_at, :utc_datetime

    embeds_one :stats, TestStats
    embeds_many :tests, TestResult
    embeds_many :failures, TestResult
    embeds_many :pending, TestResult
  end

  @doc """
  Builds a changeset for parsing test run data.
  """
  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(test_run \\ %__MODULE__{}, attrs) do
    test_run
    |> cast(attrs, [
      :file_path,
      :command,
      :exit_code,
      :execution_status,
      :seed,
      :including,
      :excluding,
      :raw_output,
      :ran_at
    ])
    |> cast_embed(:stats)
    |> cast_embed(:tests, with: &TestResult.changeset/2)
    |> cast_embed(:failures, with: &TestResult.changeset/2)
    |> cast_embed(:pending, with: &TestResult.changeset/2)
  end

  # Alias for backwards compatibility
  defdelegate parse_changeset(test_run \\ %__MODULE__{}, attrs), to: __MODULE__, as: :changeset
end
