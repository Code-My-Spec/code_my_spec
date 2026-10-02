defmodule CodeMySpec.McpServers.MainAgent.Tools.ListOffers do
  @moduledoc """
  Every nudge the harness sent this project's agents, as offers with outcomes.

  A kind × status count table, then the newest offers (default 50) with their
  subject, attempt, status and the messages they were sent as. `undelivered`
  never reached the agent. Filters: `agent_id`, `kind`, `status`, `since`
  (ISO8601), `limit`.
  """

  # Read-only. Scoped to the caller's account and project in `Offers.list/2`;
  # main-only by role grant, like the rest of `ScriptableTools`' main block.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.McpServers.MainAgent.OfferMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:agent_id, :string, doc: "One agent's offers, from `list_agent_work`.")

    field(:kind, :string,
      doc: "work, menu, problems, resume, retry, answer, unblocked or check_in."
    )

    field(:status, :string,
      doc: "open, claimed, declined, ignored, superseded, expired, n_a or undelivered."
    )

    field(:since, :string, doc: "ISO8601 — only offers made at or after this time.")
    field(:limit, :integer, doc: "How many offers to show, newest first. Defaults to 50.")
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, filters} <- filters(params),
         :ok <- own_agent(scope, filters[:agent_id]) do
      {:reply,
       OfferMapper.listing(
         Offers.list(scope, filters),
         Offers.count_by_kind_and_status(scope, filters)
       ), frame}
    else
      {:error, reason} -> {:reply, OfferMapper.error(reason), frame}
    end
  end

  defp filters(params) do
    with {:ok, kind} <- enum(:kind, fetch(params, :kind), Offer.kinds()),
         {:ok, status} <- enum(:status, fetch(params, :status), Offer.statuses()),
         {:ok, since} <- since(fetch(params, :since)) do
      {:ok,
       [agent_id: fetch(params, :agent_id), kind: kind, status: status, since: since]
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> put_limit(fetch(params, :limit))}
    end
  end

  defp enum(_field, nil, _allowed), do: {:ok, nil}

  defp enum(field, value, allowed) do
    case Enum.find(allowed, &(to_string(&1) == value)) do
      nil -> {:error, {:bad_value, field, value, Enum.map(allowed, &to_string/1)}}
      atom -> {:ok, atom}
    end
  end

  defp since(nil), do: {:ok, nil}

  defp since(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> {:error, {:bad_since, value}}
    end
  end

  defp put_limit(filters, limit) when is_integer(limit) and limit > 0,
    do: Keyword.put(filters, :limit, limit)

  defp put_limit(filters, _limit), do: filters

  # Another project's agent is refused rather than answered with an empty list,
  # which would read as an agent that was never offered anything.
  defp own_agent(_scope, nil), do: :ok

  defp own_agent(scope, agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, _agent} -> :ok
      _ -> {:error, :no_such_agent}
    end
  end

  defp fetch(params, key), do: Map.get(params, key) || Map.get(params, to_string(key))
end
