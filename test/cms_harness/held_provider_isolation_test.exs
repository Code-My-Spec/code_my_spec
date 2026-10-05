defmodule CmsHarnessTest.HeldProviderIsolationTest do
  use ExUnit.Case, async: true

  alias CmsHarnessTest.HeldProvider

  test "starting another endpoint cannot reset or release an existing endpoint" do
    first_url = HeldProvider.start()
    first_store = Process.get(HeldProvider.Store)
    HeldProvider.hold()

    first_request =
      Task.async(fn ->
        Req.post!(first_url <> "/v1/chat/completions",
          body: "first endpoint",
          retry: false,
          receive_timeout: 30_000
        )
      end)

    :ok = HeldProvider.await_request()
    second_url = HeldProvider.start()
    assert HeldProvider.seen() == []

    response =
      Req.post!(second_url <> "/v1/chat/completions",
        body: "second endpoint",
        retry: false
      )

    assert response.status == 200
    assert HeldProvider.seen() == ["second endpoint"]
    assert GenServer.call(first_store, :seen) == ["first endpoint"]
    assert :sys.get_state(first_store).mode == :holding
    assert Task.yield(first_request, 0) == nil

    :ok = GenServer.call(first_store, :release)
    assert Task.await(first_request, 30_000).status == 200
    assert HeldProvider.seen() == ["second endpoint"]
  end

  test "child tasks use their scenario's endpoint store" do
    HeldProvider.start()
    HeldProvider.refuse()
    assert Task.async(fn -> HeldProvider.seen() end) |> Task.await() == []
  end
end
