defmodule CodeMySpec.Content.S3Client do
  @moduledoc """
  Uploads objects to the user's own S3/R2 bucket (story 712) via `ExAws.S3`,
  which owns SigV4 signing. Credentials come from the local `:ex_aws` config
  (the user's AWS keys in the local CLI env) — never the SaaS.

  HTTP flows through `CodeMySpec.Content.ExAwsReqClient` (a Req-backed ExAws
  client), so specs intercept uploads by configuring a `Req.Test` plug under
  this module's app env:

      Application.put_env(:code_my_spec, #{inspect(__MODULE__)}, plug: {Req.Test, #{inspect(__MODULE__)}})

  Optional per-deployment S3 config (e.g. an R2 endpoint) can be set under
  `:s3_config` in this module's app env and is merged into the ExAws request.
  """

  alias CodeMySpec.Content.ExAwsReqClient

  @doc """
  PUT `body` to `s3://<bucket>/<key>`. Returns `:ok` on success, `{:error, _}`
  otherwise.
  """
  @spec put_object(String.t(), String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def put_object(bucket, key, body, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    bucket
    |> ExAws.S3.put_object(key, body, content_type: content_type)
    |> ExAws.request(request_config())
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_config do
    extra = Application.get_env(:code_my_spec, __MODULE__, [])[:s3_config] || []
    Keyword.merge([http_client: ExAwsReqClient], extra)
  end
end
