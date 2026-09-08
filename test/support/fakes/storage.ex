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

  @doc """
  Put an object in without going through S3.

  For the one caller that is not an S3 client: `bin/backup` uploads its dump
  from the box, and in the shell fake that upload has to land somewhere or the
  listing criterion 8014 reads reports no dumps after a run that reported
  success — the precise failure story 968 exists to catch, reported falsely.
  """
  def put_object(agent, bucket, key, body, taken_at \\ nil) do
    stamp = taken_at || DateTime.utc_now()

    Agent.update(agent, fn state ->
      objects = state.buckets |> Map.get(bucket, %{}) |> Map.put(key, {body, stamp})
      %{state | buckets: Map.put(state.buckets, bucket, objects)}
    end)
  end

  @doc """
  Drop every object under a prefix.

  For the premise that dumps *stopped*: a run that just installed the schedule
  also just took a dump, and a fresh one reads as healthy however old the rest
  are — so 968/8015 has to clear what this run made before saying the newest
  is days old.
  """
  def clear_prefix(agent, bucket, prefix) do
    Agent.update(agent, fn state ->
      objects =
        state.buckets
        |> Map.get(bucket, %{})
        |> Enum.reject(fn {key, _} -> String.starts_with?(key, prefix) end)
        |> Map.new()

      %{state | buckets: Map.put(state.buckets, bucket, objects)}
    end)
  end

  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)

    {status, headers, response} =
      Agent.get_and_update(
        agent,
        &route(conn.method, bucket(conn), key(conn), body, conn.query_params, &1)
      )

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

  # `ensure_bucket/3` polls this after creating one, because a fresh Hetzner
  # bucket 404s for about a second. Without it here the poll got the catch-all,
  # ExAws retried each attempt with backoff, and twenty attempts of that is a
  # test that hangs rather than fails — which is how this fake first looked
  # broken when it was merely incomplete.
  defp route("HEAD", bucket, "", _body, _params, state) do
    if Map.has_key?(state.buckets, bucket),
      do: {{200, [], ""}, state},
      else: {{404, [], ""}, state}
  end

  defp route("GET", nil, _key, _body, _params, state) do
    {{200, [], list_buckets_xml(Map.keys(state.buckets))}, state}
  end

  defp route("GET", "", _key, _body, _params, state) do
    {{200, [], list_buckets_xml(Map.keys(state.buckets))}, state}
  end

  # Every sub-resource before this one, because "create the bucket" is `PUT
  # /<bucket>/` with *no* query and this clause matched it with any. The
  # lifecycle rule is the same request plus `?lifecycle`, so it was being
  # swallowed here and quietly creating an already-existing bucket: the rule
  # was never stored, `GET ?lifecycle` 404'd, and criterion 8016 read a bucket
  # with no retention on it while the step that set one reported success.
  defp route("PUT", bucket, "", body, %{"lifecycle" => _}, state) do
    {{200, [], ""}, %{state | lifecycles: Map.put(state.lifecycles, bucket, body)}}
  end

  defp route("PUT", bucket, "", _body, params, state) when map_size(params) == 0 do
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

  # -- lifecycle: written above (before the bucket-create clause could swallow
  # it), and readable back, because 8016 turns on the difference between
  # setting a rule and pruning by hand --

  defp route("GET", bucket, "", _body, %{"lifecycle" => _}, state) do
    case Map.get(state.lifecycles, bucket) do
      nil -> {{404, [], error_xml("NoSuchLifecycleConfiguration")}, state}
      xml -> {{200, [], xml}, state}
    end
  end

  # -- objects --

  defp route("PUT", bucket, key, body, _params, state) do
    objects = state.buckets |> Map.get(bucket, %{}) |> Map.put(key, {body, DateTime.utc_now()})

    {{200, [{"etag", ~s("#{:erlang.phash2(body)}")}], ""},
     %{state | buckets: Map.put(state.buckets, bucket, objects)}}
  end

  # Expired objects are not listed, because the bucket really does remove them.
  #
  # Criterion 8016 is "backups past the retention window are gone", and its
  # whole point is that the *bucket* enforces it rather than a script somebody
  # hopes ran. A fake that listed every object it was ever given would fail
  # that criterion against a lifecycle rule that is working perfectly, and one
  # that ignored the rule would pass it against no rule at all.
  defp route("GET", bucket, "", _body, params, state) do
    listed =
      state.buckets
      |> Map.get(bucket, %{})
      |> Enum.filter(fn {key, {_body, _stamp}} ->
        String.starts_with?(key, params["prefix"] || "")
      end)
      |> Enum.reject(fn {_key, {_body, stamp}} -> expired?(stamp, state.lifecycles[bucket]) end)
      |> Enum.sort_by(&elem(&1, 0))

    {{200, [], list_objects_xml(bucket, listed)}, state}
  end

  defp route("GET", bucket, key, _body, _params, state) do
    case state.buckets |> Map.get(bucket, %{}) |> Map.get(key) do
      nil -> {{404, [], error_xml("NoSuchKey")}, state}
      {body, _stamp} -> {{200, [], body}, state}
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

  defp expired?(_stamp, nil), do: false

  defp expired?(stamp, days) when is_integer(days) do
    DateTime.diff(DateTime.utc_now(), stamp, :day) > days
  end

  defp expired?(stamp, lifecycle) do
    case Regex.run(~r/<Days>(\d+)<\/Days>/, to_string(lifecycle)) do
      [_, days] -> expired?(stamp, String.to_integer(days))
      _ -> false
    end
  end

  # Each object's own timestamp, not a fixed one. Everything that reads a
  # listing reads it to answer a question about *time* — is last night's dump
  # there, is this one past its window — and a constant makes every dump the
  # same age, which is either always fresh or always stale depending on the day
  # the suite runs.
  defp list_objects_xml(bucket, listed) do
    contents =
      Enum.map_join(listed, "", fn {key, {_body, stamp}} ->
        "<Contents><Key>#{key}</Key><Size>1</Size>" <>
          "<LastModified>#{DateTime.to_iso8601(stamp)}</LastModified></Contents>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult><Name>#{bucket}</Name><KeyCount>#{length(listed)}</KeyCount>#{contents}</ListBucketResult>
    """
  end

  defp error_xml(code) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>#{code}</Code><Message>#{code}</Message></Error>
    """
  end
end
