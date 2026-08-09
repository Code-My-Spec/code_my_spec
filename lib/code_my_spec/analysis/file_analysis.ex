defmodule CodeMySpec.Analysis.FileAnalysis do
  @moduledoc """
  One fact: which content of a file a given analyzer read, and when.

  The half of an analyzer's output that has never been recorded. `problems`
  already says "this file had this problem at this content" — `file_fingerprint`
  plus `ProblemRepository.reject_superseded/1` — so a finding whose file has
  moved is dropped automatically and correctly.

  Nothing said "this file was clean at this content". So a file with no problems
  and a file nobody analysed are the same shape: no rows. `tests_passing` and
  `no_problems` are `count == 0`, which reads *clean* out of an *absence*.

  That is the project's invariant sitting in the schema:

  > Absent information must not render as good news.

  With this row, clean is a row whose fingerprint matches the file's, and
  unlooked-at is no row, and the two stop being the same answer.

  ## The fingerprint is what the analyzer saw

  Not what the file has now. Stamping it from `files` at reconcile time would
  record "analysed at the current content" for a file whose older bytes the tool
  actually read — a false fact, stored permanently, which is worse than a stale
  message because nothing later contradicts it. The value travels with the
  result.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "file_analyses" do
    field :source, :string
    field :fingerprint, :string
    field :analyzed_at, :utc_datetime_usec

    field :file_id, :binary_id
    field :project_id, :binary_id
    field :harness_id, :binary_id
    field :run_id, :integer

    timestamps(type: :utc_datetime)
  end

  @required [:file_id, :project_id, :harness_id, :source, :fingerprint, :analyzed_at]
  @optional [:run_id]

  @doc false
  def changeset(analysis, attrs) do
    analysis
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    # A coverage row with an unknown fingerprint asserts nothing, and would
    # reintroduce exactly the ambiguity this table removes.
    |> validate_change(:fingerprint, fn :fingerprint, fp ->
      if is_binary(fp) and fp != "", do: [], else: [fingerprint: "must name the content read"]
    end)
    |> unique_constraint([:harness_id, :file_id, :source])
  end
end
