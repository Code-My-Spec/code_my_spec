defmodule CodeMySpec.McpServers.GoogleTools do
  @moduledoc """
  Shared helpers for the Google Search Console (`Gsc`) and Google Analytics
  (`Ga4`) MCP tool modules.

  Both servers resolve the same things on every call — a user scope from the
  local working dir, and a valid Google OAuth token for that scope — and
  render results as text-only MCP responses (structured_content is avoided
  per project convention; the JSON payload is embedded in the text instead).
  """

  alias Anubis.Server.Response
  alias CodeMySpec.Google.Auth
  alias CodeMySpec.McpServers.Validators

  @doc """
  Resolves `{scope, token}` for a tool call, or returns a tagged error the
  callers pass straight to `error/1`.
  """
  @spec resolve(map(), map()) :: {:ok, {map(), String.t()}} | {:error, term()}
  def resolve(frame, params) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, token} <- Auth.get_valid_token(scope) do
      {:ok, {scope, token}}
    end
  end

  @doc """
  Builds a text-only tool response: a human summary followed by the data as
  pretty JSON.
  """
  @spec ok(String.t(), term()) :: Response.t()
  def ok(summary, data) do
    body = summary <> "\n\n```json\n" <> encode(data) <> "\n```"

    Response.tool()
    |> Response.text(body)
  end

  @doc "Builds a plain-text tool response (no JSON payload)."
  @spec text(String.t()) :: Response.t()
  def text(message) do
    Response.tool()
    |> Response.text(message)
  end

  @doc """
  Whether destructive Search Console operations (add_site, delete_site,
  delete_sitemap) are enabled. Mirrors the upstream `GSC_ALLOW_DESTRUCTIVE`
  flag; off by default. Set via `config :code_my_spec, CodeMySpec.Google.Gsc,
  allow_destructive: true` or the `GSC_ALLOW_DESTRUCTIVE` env var.
  """
  @spec destructive_allowed?() :: boolean()
  def destructive_allowed? do
    config =
      Application.get_env(:code_my_spec, CodeMySpec.Google.Gsc, [])
      |> Keyword.get(:allow_destructive)

    case config do
      nil -> String.downcase(System.get_env("GSC_ALLOW_DESTRUCTIVE", "false")) in ~w(true 1 yes)
      bool -> bool
    end
  end

  @doc "Safety message returned when a destructive op is attempted while disabled."
  @spec destructive_disabled(String.t()) :: Response.t()
  def destructive_disabled(op) do
    text(
      "Safety: #{op} modifies your GSC account and is disabled by default. " <>
        "Set GSC_ALLOW_DESTRUCTIVE=true (or config allow_destructive: true) to enable it."
    )
  end

  @doc """
  Maps a client/auth error tuple to a friendly text-only error response.
  """
  @spec error(term()) :: Response.t()
  def error(:google_not_connected) do
    err(
      "Google account not connected. Connect Google with the Search Console / Analytics scopes, then retry."
    )
  end

  def error(:not_found), do: err("Google integration not found for this user.")
  def error(:no_refresh_token), do: err("Google token expired and no refresh token is stored. Reconnect Google.")
  def error(:no_working_dir), do: err("No working directory resolved for this request.")
  def error(:unauthorized), do: err("Unauthorized: could not resolve a project scope.")
  def error(:no_urls), do: err("No URLs provided for inspection.")

  def error({:too_many_urls, n}),
    do: err("Too many URLs provided (#{n}). Limit to 10 per batch to avoid API quota issues.")

  def error({:invalid_property_id, value}),
    do:
      err(
        "Invalid property ID: #{inspect(value)}. Use a number or a string like \"properties/123456789\"."
      )

  def error({:invalid_data_state, value}),
    do: err("Invalid data_state #{inspect(value)}. Use \"all\" or \"final\".")

  def error(:empty_funnel_steps), do: err("funnel_steps must contain at least one step.")
  def error({:invalid_funnel_step, i}), do: err("Funnel step #{i} must contain either a \"filter_expression\" or an \"event\" key.")
  def error(:invalid_filters), do: err("Invalid filters: expected a non-empty list of filter objects.")
  def error(:invalid_filter_shape), do: err("Each filter must have \"dimension\", \"operator\", and \"expression\" keys.")

  def error(:no_developer_token),
    do:
      err(
        "Google Ads developer token not configured. Set GOOGLE_ADS_DEVELOPER_TOKEN on the server."
      )

  # Google API HTTP errors — surface status + the API's message when present.
  def error({tag, status, body}) when tag in [:gsc_error, :ga4_error, :ads_error] do
    err("Google API returned #{status}: #{api_message(body)}")
  end

  def error(reason), do: err("Unexpected error: #{inspect(reason)}")

  @doc "Helpful message for a 404 from a Search Console property."
  @spec site_not_found(String.t()) :: String.t()
  def site_not_found(site_url) do
    base =
      "Property '#{site_url}' not found (404). Run list_properties to get the exact site_url, " <>
        "confirm the authenticated account has access, and remember domain properties use the " <>
        "'sc-domain:example.com' format."

    base
  end

  defp err(message) do
    Response.tool()
    |> Response.error(message)
  end

  defp api_message(%{"error" => %{"message" => msg}}), do: msg
  defp api_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp api_message(body) when is_binary(body), do: body
  defp api_message(other), do: inspect(other)

  defp encode(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(data)
    end
  end
end
