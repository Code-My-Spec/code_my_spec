defmodule CodeMySpec.ResearchSearchTest do
  @moduledoc """
  Searching the web: which provider gets picked, what each one is asked, and
  what an operator is told when there is nothing to ask.

  HTTP is stubbed through `Req.Test`, which resolves a stub against the calling
  process. `config/test.exs` pins the plug and a Tavily key; a test that wants
  a different provider overrides the key config for its own duration — which is
  why this file is not async, see below.
  """

  # Not async: these mutate `Application.env` to choose a provider, and
  # application env is global. Run concurrently, one file's `brave_api_key`
  # resolves a provider inside another file's "nothing is configured" test,
  # which then makes a real request with no stub installed and raises. The
  # `Req.Test` stubs are per-process and fine; the config is what cannot be
  # shared (`reference_req_test_stub_for_async_tests`).
  use ExUnit.Case, async: false

  alias CodeMySpec.Research
  alias CodeMySpec.Research.Search

  # Restored by `on_exit` rather than an `after`: `try` is not allowed in a test
  # file here, and teardown registered this way runs even when an assertion
  # raises — which is when a leaked provider key does the most damage, since the
  # next file to run inherits it.
  defp configure(overrides) do
    previous = Application.get_env(:code_my_spec, Research, [])

    # Start from the plug and drop every key, so "which provider" is decided by
    # what this test sets rather than by what config/test.exs happens to hold.
    base =
      Keyword.drop(previous, [:tavily_api_key, :brave_api_key, :serper_api_key, :search_provider])

    Application.put_env(:code_my_spec, Research, Keyword.merge(base, overrides))
    on_exit(fn -> Application.put_env(:code_my_spec, Research, previous) end)
  end

  describe "choosing a provider" do
    test "uses a Brave key when that is the one set" do
      configure(brave_api_key: "brave-key")
      assert {:ok, Search.Brave, "brave-key"} = Research.search_provider()
    end

    test "and a Serper key when that is" do
      configure(serper_api_key: "serper-key")
      assert {:ok, Search.Serper, "serper-key"} = Research.search_provider()
    end

    test "prefers Tavily when more than one key is set" do
      configure(tavily_api_key: "t", brave_api_key: "b", serper_api_key: "s")
      assert {:ok, Search.Tavily, "t"} = Research.search_provider()
    end

    test "an explicit provider wins over a key that is merely present" do
      configure(search_provider: :brave, tavily_api_key: "t", brave_api_key: "b")
      assert {:ok, Search.Brave, "b"} = Research.search_provider()
    end

    test "with no key at all it names every variable that would fix it" do
      configure([])

      assert {:error, {:no_provider, names}} = Research.search("anything")

      assert "TAVILY_API_KEY" in names
      assert "BRAVE_API_KEY" in names
      assert "SERPER_API_KEY" in names
    end

    test "a configured provider whose key is missing says which key" do
      configure(search_provider: :tavily)
      assert {:error, {:no_key, "TAVILY_API_KEY"}} = Research.search("anything")
    end
  end

  describe "Tavily" do
    test "sends the query and returns normalised results" do
      Req.Test.stub(Research, fn conn ->
        assert conn.method == "POST"
        assert conn.host == "api.tavily.com"

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{"query" => "ecto upsert", "max_results" => 3, "time_range" => "week"} =
                 Jason.decode!(body)

        Req.Test.json(conn, %{
          "results" => [
            %{
              "title" => "Ecto.Repo.insert/2",
              "url" => "https://hexdocs.pm/ecto",
              "content" => "on_conflict"
            }
          ]
        })
      end)

      configure(tavily_api_key: "t")

      assert {:ok, [result]} = Research.search("ecto upsert", num_results: 3, recency: :week)
      assert result.title == "Ecto.Repo.insert/2"
      assert result.url == "https://hexdocs.pm/ecto"
      assert result.snippet == "on_conflict"
    end
  end

  describe "Brave" do
    test "reads results out of the nested web key, and translates recency" do
      Req.Test.stub(Research, fn conn ->
        assert conn.method == "GET"
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["q"] == "phoenix liveview uploads"
        assert conn.params["count"] == "2"
        # Brave spells "last month" `pm`, and nothing else understands that.
        assert conn.params["freshness"] == "pm"
        assert Plug.Conn.get_req_header(conn, "x-subscription-token") == ["brave-key"]

        Req.Test.json(conn, %{
          "web" => %{
            "results" => [
              %{"title" => "Uploads", "url" => "https://example.com", "description" => "how to"}
            ]
          }
        })
      end)

      configure(brave_api_key: "brave-key")

      assert {:ok, [result]} =
               Research.search("phoenix liveview uploads", num_results: 2, recency: :month)

      assert result.snippet == "how to"
    end

    test "a 200 with no web key is no results, not a crash" do
      Req.Test.stub(Research, fn conn -> Req.Test.json(conn, %{"query" => %{}}) end)
      configure(brave_api_key: "b")

      assert {:ok, []} = Research.search("nothing matches this")
    end
  end

  describe "Serper" do
    test "posts the query and reads the organic list" do
      Req.Test.stub(Research, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"q" => "elixir genserver", "num" => 5, "tbs" => "qdr:d"} = Jason.decode!(body)
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["serper-key"]

        Req.Test.json(conn, %{
          "answerBox" => %{"answer" => "ignored"},
          "organic" => [
            %{"title" => "GenServer", "link" => "https://hexdocs.pm", "snippet" => "behaviour"}
          ]
        })
      end)

      configure(serper_api_key: "serper-key")

      assert {:ok, [result]} = Research.search("elixir genserver", recency: :day)
      assert result.url == "https://hexdocs.pm"
    end
  end

  describe "when the provider says no" do
    test "an expired key comes back as the status and the provider's own words" do
      Req.Test.stub(Research, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Invalid API key"})
      end)

      configure(tavily_api_key: "stale")

      assert {:error, {:status, 401, "Invalid API key"}} = Research.search("anything")
    end

    test "and quota exhaustion is a different status, so it can be told apart" do
      Req.Test.stub(Research, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => %{"detail" => "quota"}})
      end)

      configure(tavily_api_key: "spent")

      assert {:error, {:status, 429, "quota"}} = Research.search("anything")
    end

    test "a transport failure comes back as a message rather than an exception" do
      Req.Test.stub(Research, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      configure(tavily_api_key: "t")

      assert {:error, message} = Research.search("anything")
      assert is_binary(message)
    end
  end
end
