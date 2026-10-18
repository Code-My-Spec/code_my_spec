defmodule CodeMySpec.Agents.Tools.ListOffers do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Tools.OfferResponses, as: OfferMapper

  @impl true
  def name, do: "list_offers"

  @impl true
  def description do
    """
    Every nudge the harness sent this project's agents, as offers with outcomes.

    A kind × status count table, then the newest offers (default 50) with their
    subject, attempt, status and the messages they were sent as. `undelivered`
    never reached the agent. Filters: `agent_id`, `kind`, `status`, `since`
    (ISO8601), `limit`.
    """
  end

  @impl true
  def params do
    %{
      status:
        {:meta, :string,
         [
           description:
             "open, claimed, declined, ignored, superseded, expired, n_a or undelivered."
         ]},
      limit:
        {:meta, :integer, [description: "How many offers to show, newest first. Defaults to 50."]},
      kind:
        {:meta, :string,
         [
           description:
             "work, menu, problems, resume, retry, answer, unblocked, check_in or stalled."
         ]},
      since: {:meta, :string, [description: "ISO8601 — only offers made at or after this time."]},
      agent_id: {:meta, :string, [description: "One agent's offers, from `list_agent_work`."]}
    }
  end

  @impl true
  def call(params, context) do
    case offers(params, context) do
      {:ok, offers, counts} -> OfferMapper.listing(offers, counts)
      {:error, reason} -> OfferMapper.error(reason)
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, offers, _counts} <- offers(params, context) do
      {:ok, Enum.map(offers, &row/1)}
    end
  end

  defp offers(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, filters} <- filters(params),
         :ok <- own_agent(scope, filters[:agent_id]) do
      {:ok, Offers.list(scope, filters), Offers.count_by_kind_and_status(scope, filters)}
    end
  end

  defp row(o) do
    %{
      "id" => o.id,
      "agent_id" => o.agent_id,
      "kind" => to_string(o.kind),
      "subject_type" => o.subject_type,
      "subject_key" => o.subject_key,
      "attempt" => o.attempt,
      "status" => to_string(o.status),
      "reason" => o.reason
    }
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
