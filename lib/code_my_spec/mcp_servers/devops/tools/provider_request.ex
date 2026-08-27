defmodule CodeMySpec.McpServers.Devops.Tools.ProviderRequest do
  @moduledoc """
  Make an arbitrary Hetzner, Cloudflare or Resend API call on the agent's
  behalf, without the agent ever holding the credential.

  `Hetzner`/`Cloudflare`/`Resend` each already resolve their own credential
  server-side and make the authenticated call — that's the same "agent asks,
  server acts" shape every other provisioning tool here already uses. This
  is that plumbing, generalized: the fixed provisioning-step tools
  (`run_devops_setup`, `ensure_environment`, ...) cover the sequence; this
  covers everything that doesn't fit the sequence — inspecting what's
  already on a shared box before adopting it, attaching a firewall to a
  server that already exists, confirming something reached the provider at
  all.

  Reads are unrestricted. A mutating method (POST/PUT/PATCH/DELETE) without
  `confirm: true` is refused outright — this exists to make destructive
  action against a real account deliberate, not a thing an agent can do by
  constructing the wrong path on a whim. Every mutating call, confirmed or
  refused, is logged with enough detail to reconstruct what happened and why.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend}

  @mutating ~w(post put patch delete)

  schema do
    field :provider, :string,
      required: true,
      doc: "\"hetzner\", \"cloudflare\", or \"resend\"."

    field :method, :string, required: true, doc: "HTTP method: GET, POST, PUT, PATCH, DELETE."

    field :path, :string,
      required: true,
      doc: "Path relative to the provider's API base, e.g. \"/servers\" or \"/zones\"."

    field :body, :map, doc: "JSON body for a mutating request."
    field :params, :map, doc: "Query parameters for a GET request."

    field :confirm, :boolean,
      doc: "Required (true) for POST/PUT/PATCH/DELETE. Ignored for GET."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, provider} <- provider_module(params[:provider]),
         {:ok, method} <- parse_method(params[:method]),
         :ok <- confirmed(method, params[:confirm]) do
      log(method, params)

      provider.request(scope, method, params[:path], request_opts(params))
      |> reply(frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp provider_module("hetzner"), do: {:ok, Hetzner}
  defp provider_module("cloudflare"), do: {:ok, Cloudflare}
  defp provider_module("resend"), do: {:ok, Resend}
  defp provider_module(other), do: {:error, "unknown provider #{inspect(other)} — use hetzner, cloudflare, or resend"}

  defp parse_method(method) when is_binary(method) do
    case method |> String.downcase() |> String.to_existing_atom() do
      atom when atom in [:get, :post, :put, :patch, :delete] -> {:ok, atom}
      atom -> {:error, "unsupported method #{atom}"}
    end
  rescue
    ArgumentError -> {:error, "unsupported method #{inspect(method)}"}
  end

  defp confirmed(method, confirm) do
    if Atom.to_string(method) in @mutating and confirm != true do
      {:error,
       "#{String.upcase(Atom.to_string(method))} requires confirm: true — this call would mutate the real provider account"}
    else
      :ok
    end
  end

  defp request_opts(params) do
    []
    |> maybe_put(:json, params[:body])
    |> maybe_put(:params, params[:params])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Every mutating call, whether it goes on to succeed or gets refused above
  # for lacking confirm: true — a refusal is still evidence of what an agent
  # just tried, and that's exactly the case an audit trail exists for.
  defp log(method, params) do
    if Atom.to_string(method) in @mutating do
      Logger.warning(
        "[ProviderRequest] #{params[:provider]} #{String.upcase(Atom.to_string(method))} " <>
          "#{params[:path]} body=#{inspect(params[:body])}"
      )
    end
  end

  defp reply({:ok, body}, frame), do: {:reply, ok(inspect(body, pretty: true, limit: :infinity)), frame}
  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Provider request failed: #{inspect(reason)}")
end
