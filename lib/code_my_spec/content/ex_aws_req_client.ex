defmodule CodeMySpec.Content.ExAwsReqClient do
  @moduledoc """
  ExAws HTTP client backed by Req, so ExAws S3 operations (which own SigV4
  signing) still flow through Req — and therefore through `Req.Test` stubs in
  specs. The test plug is read from `CodeMySpec.Content.S3Client`'s app env, so
  the same `plug: {Req.Test, S3Client}` config the specs set intercepts the
  upload.
  """
  @behaviour ExAws.Request.HttpClient

  # Req's default receive timeout is fifteen seconds, and this discarded the
  # caller's `http_opts` entirely — so no caller could ask for longer, and a
  # request that legitimately takes longer could never succeed however many
  # times it was retried. Listing a registry bucket does: it holds one object
  # per image layer, and `mix cms.provisioning_leaks --delete` sat in a retry
  # loop against the same timeout for half an hour, unable to clear a bucket
  # whose only problem was being big.
  @default_receive_timeout :timer.minutes(2)

  @impl true
  def request(method, url, body, headers, http_opts \\ []) do
    opts =
      [
        method: method,
        url: url,
        body: body,
        headers: headers,
        decode_body: false,
        retry: false,
        receive_timeout: receive_timeout(http_opts)
      ]
      |> maybe_plug()

    case Req.request(opts) do
      {:ok, resp} ->
        {:ok, %{status_code: resp.status, headers: Map.to_list(resp.headers), body: to_iodata(resp.body)}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  # ExAws speaks hackney's `:recv_timeout`; Req calls it `:receive_timeout`.
  # Either is honoured so a caller does not have to know which library is
  # underneath.
  defp receive_timeout(http_opts) do
    Keyword.get(http_opts, :receive_timeout) ||
      Keyword.get(http_opts, :recv_timeout) ||
      @default_receive_timeout
  end

  defp maybe_plug(opts) do
    case Application.get_env(:code_my_spec, CodeMySpec.Content.S3Client, [])[:plug] do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp to_iodata(body) when is_binary(body), do: body
  defp to_iodata(body), do: :erlang.term_to_binary(body)
end
