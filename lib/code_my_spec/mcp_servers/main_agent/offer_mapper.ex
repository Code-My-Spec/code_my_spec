defmodule CodeMySpec.McpServers.MainAgent.OfferMapper do
  @moduledoc "Text for `list_offers`: a kind × status count table, then each offer and its messages."

  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Conversations.Message

  @excerpt 300

  @doc "The listing. `counts` cover every match; `offers` are the newest `limit` of them."
  @spec listing([Offer.t()], %{{atom(), atom()} => pos_integer()}) :: Response.t()
  def listing(offers, counts) do
    Response.tool() |> Response.text(text(offers, counts))
  end

  @doc "The listing as plain text."
  @spec text([Offer.t()], map()) :: String.t()
  def text(_offers, counts) when map_size(counts) == 0, do: "No offers match."

  def text(offers, counts) do
    total = counts |> Map.values() |> Enum.sum()

    Enum.join(
      [
        "#{total} offers match; the newest #{length(offers)} are shown below.",
        "",
        table(counts),
        "" | Enum.map(offers, &block/1)
      ],
      "\n"
    )
  end

  @doc "The kind × status count table: only kinds and statuses that occur, with row totals."
  @spec table(map()) :: String.t()
  def table(counts) do
    kinds = present(Offer.kinds(), counts, fn {kind, _status} -> kind end)
    statuses = present(Offer.statuses(), counts, fn {_kind, status} -> status end)
    header = ["kind" | Enum.map(statuses, &to_string/1)] ++ ["total"]

    rows =
      Enum.map(kinds, fn kind ->
        cells = Enum.map(statuses, &Map.get(counts, {kind, &1}, 0))
        [to_string(kind) | Enum.map(cells, &to_string/1)] ++ [to_string(Enum.sum(cells))]
      end)

    widths =
      [header | rows]
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map_join([header | rows], "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.with_index()
      |> Enum.map_join("  ", fn
        {{cell, width}, 0} -> String.pad_trailing(cell, width)
        {{cell, width}, _} -> String.pad_leading(cell, width)
      end)
      |> String.trim_trailing()
    end)
  end

  # In the schema's order, and only those with a count.
  defp present(all, counts, pick) do
    seen = counts |> Map.keys() |> MapSet.new(pick)
    Enum.filter(all, &MapSet.member?(seen, &1))
  end

  defp block(%Offer{} = offer) do
    [
      "offer #{offer.id}",
      "  agent: #{offer.agent_id} (#{role(offer)})",
      "  #{offer.kind} on #{subject(offer)}, attempt #{offer.attempt}",
      "  status: #{status(offer)}",
      "  created: #{at(offer.inserted_at)}  outcome: #{at(offer.outcome_at)}",
      "  template: #{offer.template_version}"
    ]
    |> maybe("  reason: ", offer.reason)
    |> maybe("  note: ", offer.note)
    |> Kernel.++(messages(offer.messages))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp role(%Offer{agent: %{role: role}}), do: to_string(role)
  defp role(_offer), do: "agent gone"

  defp subject(%Offer{subject_type: type, subject_key: nil}), do: type
  defp subject(%Offer{subject_type: type, subject_key: key}), do: "#{type}:#{key}"

  defp status(%Offer{status: :undelivered}),
    do: "undelivered — the delivery failed or was held; the agent never saw it"

  defp status(%Offer{status: status}), do: to_string(status)

  defp at(nil), do: "—"
  defp at(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp maybe(lines, _label, value) when value in [nil, ""], do: lines
  defp maybe(lines, label, value), do: lines ++ [label <> value]

  defp messages([]),
    do: ["  messages: none linked — recorded without a conversation message"]

  defp messages(links) do
    ["  messages:" | Enum.map(links, &message_line/1)]
  end

  defp message_line(%{message: %Message{} = message}) do
    "    - #{message.id} at #{at(message.inserted_at)}: #{excerpt(Message.text(message))}"
  end

  defp message_line(%{message_id: id}), do: "    - #{id}: message no longer exists"

  defp excerpt(nil), do: ""

  defp excerpt(text) do
    flat = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(flat) > @excerpt,
      do: String.slice(flat, 0, @excerpt) <> "…",
      else: flat
  end

  @doc "Why the listing was refused."
  @spec error(term()) :: Response.t()
  def error(:no_such_agent) do
    Response.tool()
    |> Response.error(
      "No agent with that id on this project. `list_agent_work` has the ids; " <>
        "this takes the whole one."
    )
  end

  def error({:bad_value, field, value, allowed}) do
    Response.tool()
    |> Response.error("`#{field}` #{inspect(value)} is not one of: #{Enum.join(allowed, ", ")}.")
  end

  def error({:bad_since, value}) do
    Response.tool()
    |> Response.error("`since` #{inspect(value)} is not ISO8601, e.g. 2026-10-02T09:00:00Z.")
  end

  def error(reason) do
    Response.tool() |> Response.error("Offers could not be listed: #{inspect(reason)}")
  end
end
