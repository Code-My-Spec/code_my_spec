defmodule CodeMySpecWeb.ProvisioningLive.ResourceFields do
  @moduledoc """
  Reading a `Resource`'s fields for display — shared by `ProvisioningLive`'s
  own rendering and every per-step config component under
  `provisioning_live/components/`, so a dns or deploy resource's environment,
  name, owner or `key=value` identifier fields are read the same way no
  matter which component is showing them.

  Pure functions only, same as before this was its own module — it still
  knows nothing about events, state, or the socket.
  """

  @doc """
  The bucket a resource belongs to encodes its environment as a suffix, which
  is what makes criterion 8012 checkable from the page: a UAT upload and a
  production one are distinguishable without asking the provider.
  The steps that fan out over environments tag what they made, because the
  page cannot know the names: a project may have `qa`, or one environment per
  story. Matching a hardcoded list against a location suffix only ever found
  the two that used to be hardcoded.
  """
  def resource_environment(resource, environments) do
    tagged(resource) || suffixed(resource, environments)
  end

  # Steps that fan out over environments tag what they made, because the page
  # cannot know the names: a project may have `qa`, or one per story.
  defp tagged(%{identifier: identifier}) when is_binary(identifier) do
    case Regex.run(~r/environment=([a-z0-9-]+)/, identifier) do
      [_, environment] -> environment
      nil -> nil
    end
  end

  defp tagged(_), do: nil

  # Not everything carries the tag. A bucket encodes its environment as a
  # suffix on the name — `app-uat` — and that is what makes criterion 8012
  # checkable from the page at all. Reading only the tag reported every bucket
  # as belonging to no environment.
  #
  # Matched against the project's own environments rather than a pattern, so a
  # name that merely happens to end in `-something` is not mistaken for one.
  defp suffixed(%{location: location}, environments) when is_binary(location) do
    Enum.find(environments, fn environment ->
      String.ends_with?(location, "-" <> environment)
    end)
  end

  defp suffixed(_resource, _environments), do: nil

  @doc "The IP an environment's record points at — the first half of the tagged identifier the DNS step writes."
  def resource_target(%{identifier: identifier}) when is_binary(identifier),
    do: identifier |> String.split(" ") |> List.first()

  def resource_target(_), do: nil

  @doc """
  Only a built image reports one — an image that already existed was not
  built here, so this page has nothing to say about what it was built for.
  Absent rather than guessed, for the same reason the build reads it off the
  image instead of echoing the request.
  """
  def image_architecture(resource), do: identifier_field(resource, "architecture")

  @doc """
  Resources tag their identifier as `key=value key=value`, which several
  steps already rely on. Read by name rather than by position: a resource
  that gains a field should not silently shift what another attribute means.
  """
  def identifier_field(%{identifier: identifier}, key) when is_binary(identifier) do
    identifier
    |> String.split(" ")
    |> Enum.find_value(fn part ->
      case String.split(part, "=", parts: 2) do
        [^key, value] -> value
        _ -> nil
      end
    end)
  end

  def identifier_field(_resource, _key), do: nil

  @doc "`key=value key=value` — the shape every proof resource uses for its identifier, so the page can pull one field without knowing the order."
  def proof_field(identifier, key) do
    identifier
    |> to_string()
    |> String.split(" ")
    |> Enum.find_value(fn part ->
      case String.split(part, "=", parts: 2) do
        [^key, value] -> value
        _ -> nil
      end
    end)
  end

  @doc "The bare name, not the endpoint-qualified location."
  def resource_name(%{location: location}) when is_binary(location),
    do: location |> String.split("/") |> List.last()

  def resource_name(_), do: nil

  def resource_disposition(%{kind: "repository", identifier: d}) when is_binary(d), do: d
  def resource_disposition(_), do: nil

  @doc """
  Recorded by the provider rather than asserted by the page. Story 968's
  whole claim is that these are Sam's, so a hardcoded "user" would make the
  attribute decorative — it would read the same for a platform-owned bucket.
  """
  def resource_owner(%{kind: "bucket", identifier: owner}) when is_binary(owner), do: owner
  def resource_owner(_), do: "user"
end
