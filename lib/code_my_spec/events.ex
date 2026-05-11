defmodule CodeMySpec.Events do
  @moduledoc """
  Generic event log. One table (`events`) with two columns of interest:
  `event_type` (the discriminator) and `data` (a JSON blob whose shape
  is event-specific). Inserts are append-only.

  Used as the source of truth for activation milestones (driving the
  dashboard onboarding ladder and per-project ladder) and any future
  domain events that need persistence beyond `:telemetry` fan-out.

  ## Usage

      Events.record("local_signed_in", %{user_id: 42})
      Events.record("local_init_complete", %{user_id: 42, project_id: "uuid"})

      Events.exists?("local_signed_in", user_id: 42)
      # => true

      Events.exists?("local_init_complete", project_id: "uuid")
      # => false
  """

  import Ecto.Query

  alias CodeMySpec.Events.Event
  alias CodeMySpec.Repo

  @doc """
  Record an event. `data` is a free-form map; convention is to include
  whatever identifiers a future `exists?/2` call will filter on.
  """
  @spec record(String.t() | atom(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def record(event_type, data \\ %{}) when is_map(data) do
    %Event{}
    |> Event.changeset(%{event_type: to_string(event_type), data: stringify_keys(data)})
    |> Repo.insert()
  end

  @doc """
  True iff at least one event of `event_type` exists matching every
  key/value in `filters` against the JSON blob. Filters are compared
  as text against `data->>key`, so callers should pass scalar values
  (integers and uuids stringify cleanly).
  """
  @spec exists?(String.t() | atom(), keyword()) :: boolean()
  def exists?(event_type, filters \\ []) do
    event_type
    |> base_query()
    |> apply_filters(filters)
    |> Repo.exists?()
  end

  defp base_query(event_type) do
    from e in Event, where: e.event_type == ^to_string(event_type)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, q ->
      key_str = to_string(key)
      value_str = to_string(value)
      from e in q, where: fragment("?->>?", e.data, ^key_str) == ^value_str
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
