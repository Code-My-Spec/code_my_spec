defmodule CodeMySpec.Research.Tools.WebToolsTest do
  @moduledoc """
  What the two tools put in front of an agent.

  The formatting is the tool: `Research` already returns structs, and the only
  thing left to get wrong here is what the agent actually reads — whether a
  truncated page admits it, whether a missing key produces something an
  operator can act on, and whether either tool can be called by someone with no
  project.
  """

  # Not async: these mutate `Application.env` to choose a provider, and
  # application env is global. Run concurrently, one file's `brave_api_key`
  # resolves a provider inside another file's "nothing is configured" test,
  # which then makes a real request with no stub installed and raises. The
  # `Req.Test` stubs are per-process and fine; the config is what cannot be
  # shared (`reference_req_test_stub_for_async_tests`).
  use ExUnit.Case, async: false

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Repo
  alias CodeMySpec.Research
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  defp frame, do: %Frame{assigns: %{current_scope: full_scope_fixture()}}

  defp text({_status, text}), do: text

  # Restored by `on_exit` rather than an `after`: `try` is not allowed in a test
  # file here, and teardown registered this way runs even when an assertion
  # raises — which is when a leaked config does the most damage, since the next
  # file to run inherits it.
  defp without_keys do
    previous = Application.get_env(:code_my_spec, Research, [])

    Application.put_env(
      :code_my_spec,
      Research,
      Keyword.drop(previous, [:tavily_api_key, :brave_api_key, :serper_api_key, :search_provider])
    )

    on_exit(fn -> Application.put_env(:code_my_spec, Research, previous) end)
  end

  describe "web_search" do
    test "lists results with their URLs, so the next step is a fetch" do
      Req.Test.stub(Research, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{
              "title" => "Ecto upserts",
              "url" => "https://hexdocs.pm/ecto",
              "content" => "on_conflict"
            },
            %{"title" => "Second", "url" => "https://example.com", "content" => ""}
          ]
        })
      end)

      frame = frame()

      response =
        ToolLibrary.run("web_search", %{query: "ecto upsert"}, %{
          scope: frame.assigns.current_scope
        })

      assert match?({:ok, _}, response)

      content = text(response)
      assert content =~ "1. Ecto upserts"
      assert content =~ "https://hexdocs.pm/ecto"
      assert content =~ "on_conflict"
      assert content =~ "2. Second"
    end

    test "says so plainly when there is nothing" do
      Req.Test.stub(Research, fn conn -> Req.Test.json(conn, %{"results" => []}) end)

      frame = frame()

      response =
        ToolLibrary.run("web_search", %{query: "zxqwv"}, %{
          scope: frame.assigns.current_scope
        })

      assert match?({:ok, _}, response)
      assert text(response) =~ "No results"
    end

    test "an unconfigured deployment gets a refusal naming the variables to set" do
      without_keys()

      frame = frame()

      response =
        ToolLibrary.run("web_search", %{query: "anything"}, %{
          scope: frame.assigns.current_scope
        })

      assert match?({:error, _}, response)
      message = text(response)

      # An agent cannot fix this; the operator reading its output can, and only
      # if the message names what to set.
      assert message =~ "TAVILY_API_KEY"
      assert message =~ "BRAVE_API_KEY"
      assert message =~ "SERPER_API_KEY"
    end

    test "rejects a recency it does not understand rather than searching without it" do
      frame = frame()

      response =
        ToolLibrary.run("web_search", %{query: "x", recency: "fortnight"}, %{
          scope: frame.assigns.current_scope
        })

      assert match?({:error, _}, response)
      assert text(response) =~ "day, week, month or year"
    end

    test "refuses a caller with no project" do
      frame = %Frame{assigns: %{current_scope: user_scope_fixture()}}

      response =
        ToolLibrary.run(
          "web_search",
          %{query: "x"},
          Map.put(frame.assigns, :scope, frame.assigns.current_scope)
        )

      assert match?({:error, _}, response)
    end
  end

  describe "web_fetch" do
    test "leads with the source, so a quoted line can be traced back" do
      Req.Test.stub(Research, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          200,
          "<html><head><title>A Page</title></head><body><main><p>Body text.</p></main></body></html>"
        )
      end)

      frame = frame()

      response =
        ToolLibrary.run("web_fetch", %{url: "https://example.com/a"}, %{
          scope: frame.assigns.current_scope
        })

      content = text(response)
      assert content =~ "# A Page"
      assert content =~ "Source: https://example.com/a"
      assert content =~ "Body text."
    end

    test "a truncated page says it was truncated" do
      Req.Test.stub(Research, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          200,
          "<html><body><main><p>#{String.duplicate("long ", 200)}</p></main></body></html>"
        )
      end)

      frame = frame()

      response =
        ToolLibrary.run(
          "web_fetch",
          %{url: "https://example.com/long", max_output: 120},
          Map.put(frame.assigns, :scope, frame.assigns.current_scope)
        )

      # Without this line the agent has the first half of a document and no way
      # to know it, which is worse than having none of it.
      assert text(response) =~ "Truncated"
    end

    test "a GitHub blob says it read the raw file instead" do
      Req.Test.stub(Research, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "defmodule Map do\nend")
      end)

      frame = frame()
      url = "https://github.com/elixir-lang/elixir/blob/main/lib/elixir/lib/map.ex"

      response =
        ToolLibrary.run(
          "web_fetch",
          %{url: url},
          Map.put(frame.assigns, :scope, frame.assigns.current_scope)
        )

      content = text(response)
      assert content =~ "raw.githubusercontent.com"
      assert content =~ "Requested: #{url}"
    end

    test "a Reddit URL says why it cannot be read, not that it failed" do
      frame = frame()

      response =
        ToolLibrary.run(
          "web_fetch",
          %{url: "https://www.reddit.com/r/elixir/comments/abc/x/"},
          Map.put(frame.assigns, :scope, frame.assigns.current_scope)
        )

      assert match?({:error, _}, response)
      message = text(response)

      assert message =~ "OAuth"
      assert message =~ "login wall"
      # The agent's next move is the point of the message.
      assert message =~ "somewhere quotable"
    end

    test "a file: URL is refused by name" do
      frame = frame()

      response =
        ToolLibrary.run("web_fetch", %{url: "file:///etc/passwd"}, %{
          scope: frame.assigns.current_scope
        })

      assert match?({:error, _}, response)
      assert text(response) =~ "Only http and https"
    end

    test "refuses a caller with no project" do
      frame = %Frame{assigns: %{current_scope: user_scope_fixture()}}

      response =
        ToolLibrary.run("web_fetch", %{url: "https://example.com"}, %{
          scope: frame.assigns.current_scope
        })

      assert match?({:error, _}, response)
    end
  end
end
