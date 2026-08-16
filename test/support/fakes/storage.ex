defmodule CodeMySpecSpex.Fakes.Storage do
  @moduledoc """
  Object storage that remembers what was put in it.

  Fourth fake. Same seam as the others — ExAws routes through
  `Content.ExAwsReqClient`, which takes its `plug` from `Content.S3Client`'s app
  env — but S3 answers XML, so this speaks XML back.

  What it models, and why each one is here:

    * **A bucket holds what you put in it**, so "the dump is in the bucket" is
      a fact about the run rather than about a recording. Story 968's criteria
      are all shaped that way.

    * **A lifecycle rule is readable after it is written.** 968/8016 wants
      retention the bucket enforces on its own, and the distinction between
      "we set a rule" and "we pruned some objects" is the whole criterion.
      Writing and reading it back keeps that honest.

    * **Listing is prefixed.** Dumps live under `dumps/<env>/`, and a criterion
      that counts them has to be able to ask for that prefix and not get the
      registry's blobs.

    * **A deleted object is gone**, so teardown is assertable.

  Not modelled: durability, consistency delay, multipart. A bucket that
  refuses to delete until emptied is real Hetzner behaviour and belongs to the
  live teardown tests, not here.
  """

  alias Plug.Conn

  @doc "Fresh storage. One per test."
  def new, do: %{buckets: %{}, lifecycles: %{}}

  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)

    {status, headers, response} =
      Agent.get_and_update(agent, &route(conn.method, bucket(conn), key(conn), body, conn.query_params, &1))

    Enum.reduce(headers, conn, fn {k, v}, acc -> Conn.put_resp_header(acc, k, v) end)
    |> Conn.send_resp(status, response)
  end

  defp read_body(conn) do
    case Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:ok, "", conn}
      {:error, _} -> {:ok, "", conn}
    end
  end

  # Path-style: /bucket/key. Hetzner's object storage is path-style, which is
  # why `Storage` configures it that way.
  defp bucket(conn) do
    conn.request_path |> String.split("/", trim: true) |> List.first()
  end

  defp key(conn) do
    conn.request_path |> String.split("/", trim: true) |> Enum.drop(1) |> Enum.join("/")
  end

  # -- buckets --

  defp route("GET", nil, _key, _body, _params, state) do
    {{200, [], list_buckets_xml(Map.keys(state.buckets))}, state}
  end

  defp route("GET", "", _key, _body, _params, state) do
    {{200, [], list_buckets_xml(Map.keys(state.buckets))}, state}
  end

  defp route("PUT", bucket, "", _body, _params, state) do
    {{200, [], ""}, %{state | buckets: Map.put_new(state.buckets, bucket, %{})}}
  end

  defp route("DELETE", bucket, "", _body, _params, state) do
    {{204, [], ""},
     %{
       state
       | buckets: Map.delete(state.buckets, bucket),
         lifecycles: Map.delete(state.lifecycles, bucket)
     }}
  end

  # -- lifecycle: written, and readable back, because 8016 turns on the
  # difference between setting a rule and pruning by hand --

  defp route("PUT", bucket, "", body, %{"lifecycle" => _}, state) do
    {{200, [], ""}, %{state | lifecycles: Map.put(state.lifecycles, bucket, body)}}
  end

  defp route("GET", bucket, "", _body, %{"lifecycle" => _}, state) do
    case Map.get(state.lifecycles, bucket) do
      nil -> {{404, [], error_xml("NoSuchLifecycleConfiguration")}, state}
      xml -> {{200, [], xml}, state}
    end
  end

  # -- objects --

  defp route("PUT", bucket, key, body, _params, state) do
    objects = state.buckets |> Map.get(bucket, %{}) |> Map.put(key, body)

    {{200, [{"etag", ~s("#{:erlang.phash2(body)}")}], ""},
     %{state | buckets: Map.put(state.buckets, bucket, objects)}}
  end

  defp route("GET", bucket, "", _body, params, state) do
    keys =
      state.buckets
      |> Map.get(bucket, %{})
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, params["prefix"] || ""))
      |> Enum.sort()

    {{200, [], list_objects_xml(bucket, keys)}, state}
  end

  defp route("GET", bucket, key, _body, _params, state) do
    case state.buckets |> Map.get(bucket, %{}) |> Map.get(key) do
      nil -> {{404, [], error_xml("NoSuchKey")}, state}
      body -> {{200, [], body}, state}
    end
  end

  defp route("DELETE", bucket, key, _body, _params, state) do
    objects = state.buckets |> Map.get(bucket, %{}) |> Map.delete(key)
    {{204, [], ""}, %{state | buckets: Map.put(state.buckets, bucket, objects)}}
  end

  defp route(method, bucket, key, _body, _params, state) do
    {{501, [], error_xml("NotModelled: #{method} #{bucket}/#{key}")}, state}
  end

  # -- xml --

  defp list_buckets_xml(names) do
    buckets = Enum.map_join(names, "", &"<Bucket><Name>#{&1}</Name></Bucket>")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListAllMyBucketsResult><Owner><ID>spex</ID></Owner><Buckets>#{buckets}</Buckets></ListAllMyBucketsResult>
    """
  end

  defp list_objects_xml(bucket, keys) do
    contents =
      Enum.map_join(keys, "", fn key ->
        "<Contents><Key>#{key}</Key><Size>1</Size>" <>
          "<LastModified>2026-01-01T00:00:00.000Z</LastModified></Contents>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult><Name>#{bucket}</Name><KeyCount>#{length(keys)}</KeyCount>#{contents}</ListBucketResult>
    """
  end

  defp error_xml(code) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>#{code}</Code><Message>#{code}</Message></Error>
    """
  end
end
