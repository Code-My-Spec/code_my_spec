defmodule CodeMySpec.Content.TriggerClient do
  @moduledoc """
  Hand-written Req client for the publish pull-trigger (story 712, criterion
  6276). After the manifest + blob are in S3, the local process POSTs to the
  deployed client's `/api/content/pull` with `Authorization: Bearer
  <deploy_key>` and the manifest URL, so the client pulls and persists.

  In tests a `Req.Test` plug (configured under this module's app env)
  intercepts the POST.

  Config (`Application.get_env(:code_my_spec, #{inspect(__MODULE__)})`):
    * `:plug` — a `{Req.Test, name}` plug (tests only)
  """

  @doc """
  POST a pull trigger to `<client_api_url>/api/content/pull` carrying the
  bearer deploy key and `manifest_url`. Returns `{:ok, %{sync_id: ...}}` on a
  200, `{:error, _}` otherwise.
  """
  @spec trigger(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def trigger(client_api_url, deploy_key, manifest_url) do
    url = "#{String.trim_trailing(client_api_url, "/")}/api/content/pull"

    [method: :post, url: url, auth: {:bearer, deploy_key}, json: %{manifest_url: manifest_url}]
    |> Req.new()
    |> attach_plug()
    |> Req.request()
    |> case do
      {:ok, %{status: status, body: body}} when status in [200, 202] ->
        {:ok, %{sync_id: sync_id(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attach_plug(req) do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp sync_id(%{"sync_id" => id}), do: id
  defp sync_id(_), do: nil
end
