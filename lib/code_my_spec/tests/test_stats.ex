defmodule CodeMySpec.Tests.TestStats do
  @moduledoc false
  use Ecto.Schema

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          duration_ms: non_neg_integer(),
          load_time_ms: non_neg_integer() | nil,
          passes: non_neg_integer(),
          failures: non_neg_integer(),
          pending: non_neg_integer(),
          invalid: non_neg_integer(),
          tests: non_neg_integer(),
          suites: non_neg_integer(),
          started_at: NaiveDateTime.t(),
          finished_at: NaiveDateTime.t()
        }

  @primary_key false
  embedded_schema do
    field :duration_ms, :integer
    field :load_time_ms, :integer
    field :passes, :integer, default: 0
    field :failures, :integer, default: 0
    field :pending, :integer, default: 0
    field :invalid, :integer, default: 0
    field :tests, :integer, default: 0
    field :suites, :integer, default: 0
    field :started_at, :naive_datetime
    field :finished_at, :naive_datetime
  end

  def changeset(test_stats \\ %__MODULE__{}, attrs) do
    test_stats
    |> Ecto.Changeset.cast(attrs, [
      :duration_ms,
      :load_time_ms,
      :passes,
      :failures,
      :pending,
      :invalid,
      :tests,
      :suites,
      :started_at,
      :finished_at
    ])
    |> map_json_fields(attrs)
  end

  defp map_json_fields(changeset, attrs) do
    changeset
    |> maybe_put_duration(attrs["duration"])
    |> maybe_put_load_time(attrs["loadTime"])
    |> maybe_put_datetime(:started_at, attrs["start"])
    |> maybe_put_datetime(:finished_at, attrs["end"])
  end

  defp maybe_put_duration(changeset, nil), do: changeset

  defp maybe_put_duration(changeset, duration) when is_number(duration) do
    Ecto.Changeset.put_change(changeset, :duration_ms, round(duration))
  end

  defp maybe_put_load_time(changeset, nil), do: changeset

  defp maybe_put_load_time(changeset, load_time) when is_number(load_time) do
    Ecto.Changeset.put_change(changeset, :load_time_ms, round(load_time))
  end

  defp maybe_put_datetime(changeset, _field, nil), do: changeset

  defp maybe_put_datetime(changeset, field, iso_string) when is_binary(iso_string) do
    case NaiveDateTime.from_iso8601(iso_string) do
      {:ok, datetime} -> Ecto.Changeset.put_change(changeset, field, datetime)
      {:error, _} -> changeset
    end
  end

  defp maybe_put_datetime(changeset, _field, _), do: changeset
end
