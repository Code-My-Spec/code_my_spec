defmodule CodeMySpec.Requirements.DependsOnType do
  @moduledoc """
  Custom Ecto type for storing depends_on edges as JSON text.

  Stores a list of `%{"entity_type" => ..., "entity_id" => ..., "requirement_name" => ...}`
  maps serialized as a JSON array string in the database.
  """
  use Ecto.Type

  def type, do: :text

  # Accept list of maps from application code
  def cast(data) when is_list(data), do: {:ok, data}
  def cast(nil), do: {:ok, []}
  def cast(_), do: :error

  # Serialize to JSON text for database
  def dump(data) when is_list(data), do: {:ok, Jason.encode!(data)}
  def dump(nil), do: {:ok, "[]"}
  def dump(_), do: :error

  # Deserialize from JSON text to list of maps
  def load(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:ok, []}
    end
  end

  def load(nil), do: {:ok, []}
  def load(data) when is_list(data), do: {:ok, data}
  def load(_), do: {:ok, []}
end
