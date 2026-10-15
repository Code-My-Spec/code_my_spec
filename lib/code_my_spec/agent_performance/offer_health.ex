defmodule CodeMySpec.AgentPerformance.OfferHealth do
  @moduledoc """
  Offer health per role: claim rate, average time to claim, and how many
  offers were ignored or declined.

  `:undelivered` offers never reached an agent and `:superseded` ones were
  overtaken by a restart before the agent could act -- neither is evidence
  about the agent, so neither counts toward or against its role's claim
  rate.
  """

  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Users.Scope

  @type role_health :: %{
          role: atom(),
          claim_rate: float() | nil,
          average_seconds_to_claim: float() | nil,
          ignored: non_neg_integer(),
          declined: non_neg_integer(),
          superseded: non_neg_integer()
        }

  @large_limit 100_000

  # Never claimed/ignored/declined, by design -- `Offers.outcome/3` settles
  # every one of these to `:n_a` regardless of what the agent does
  # ("informational" and "compliance is not inferred", per that module's own
  # moduledoc). Excluded by kind, not only by settled status, because an open
  # one -- freshly queued, not yet judged -- would otherwise read as a claim
  # rate's denominator before it ever could be one.
  @uncounted_kinds [:resume, :check_in, :instruction]

  @doc "Every role's offer health over a period. `since` omitted for all time."
  @spec by_role(Scope.t(), DateTime.t() | nil) :: [role_health()]
  def by_role(%Scope{} = scope, since \\ nil) do
    filters = if since, do: [since: since, limit: @large_limit], else: [limit: @large_limit]

    scope
    |> Offers.list(filters)
    |> Enum.filter(&(&1.status != :undelivered))
    |> Enum.group_by(&role_of/1)
    |> Enum.reject(fn {role, _offers} -> is_nil(role) end)
    |> Enum.map(fn {role, offers} -> role_health(role, offers) end)
  end

  defp role_of(%Offer{agent: %{role: role}}) when not is_nil(role), do: role
  defp role_of(_offer), do: nil

  @doc "Whether an offer counts toward a claim rate at all: not superseded, not informational."
  @spec counted?(Offer.t()) :: boolean()
  def counted?(%Offer{} = offer),
    do: offer.status != :superseded and offer.kind not in @uncounted_kinds

  defp role_health(role, offers) do
    counted = Enum.filter(offers, &counted?/1)

    claimed = Enum.filter(counted, &(&1.status == :claimed))

    %{
      role: role,
      claim_rate: rate(claimed, counted),
      average_seconds_to_claim: average_seconds_to_claim(claimed),
      ignored: Enum.count(counted, &(&1.status == :ignored)),
      declined: Enum.count(counted, &(&1.status == :declined)),
      superseded: Enum.count(offers, &(&1.status == :superseded))
    }
  end

  defp rate(_claimed, []), do: nil
  defp rate(claimed, counted), do: length(claimed) / length(counted)

  defp average_seconds_to_claim([]), do: nil

  defp average_seconds_to_claim(claimed) do
    seconds =
      claimed
      |> Enum.filter(& &1.outcome_at)
      |> Enum.map(&DateTime.diff(&1.outcome_at, &1.inserted_at))

    case seconds do
      [] -> nil
      list -> Enum.sum(list) / length(list)
    end
  end
end
