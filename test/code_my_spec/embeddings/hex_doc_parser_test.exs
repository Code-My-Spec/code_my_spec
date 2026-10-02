defmodule CodeMySpec.Embeddings.HexDocParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Embeddings.HexDocParser

  defp docs(source), do: source |> HexDocParser.docs_from_source() |> Map.new()

  test "one markdown document per documented module, named by the module" do
    result =
      docs("""
      defmodule Phoenix.Endpoint do
        @moduledoc "Phoenix endpoint module."
      end

      defmodule Phoenix.Router do
        @moduledoc "Phoenix router DSL."
      end
      """)

    assert Map.keys(result) |> Enum.sort() == ["Phoenix.Endpoint", "Phoenix.Router"]
    assert result["Phoenix.Endpoint"] =~ "# Phoenix.Endpoint"
    assert result["Phoenix.Endpoint"] =~ "Phoenix endpoint module."
  end

  test "nested modules get fully-qualified names" do
    result =
      docs("""
      defmodule Phoenix do
        @moduledoc "Top-level Phoenix."

        defmodule Token do
          @moduledoc "Nested token helper."
        end
      end
      """)

    assert result["Phoenix"] =~ "Top-level Phoenix."
    assert result["Phoenix.Token"] =~ "# Phoenix.Token"
    assert result["Phoenix.Token"] =~ "Nested token helper"
  end

  test "renders @doc'd public functions as ## fun/arity sections" do
    md =
      docs("""
      defmodule Phoenix do
        @moduledoc "Phoenix module."

        @doc "Starts the endpoint with opts."
        def start(opts), do: opts

        @doc "Returns a child spec."
        def child_spec, do: :ok

        @doc "Handles an integer."
        def handle(x) when is_integer(x), do: x
      end
      """)["Phoenix"]

    assert md =~ "## start/1"
    assert md =~ "Starts the endpoint with opts."
    assert md =~ "## child_spec/0"
    assert md =~ "## handle/1", "expected `when` guard to be unwrapped to arity 1"
  end

  test "@doc on a private def does not render (and is not mis-attached)" do
    md =
      docs("""
      defmodule Phoenix do
        @moduledoc "Phoenix module."

        @doc "this doc sits above a private function"
        defp secret(x), do: x

        def public(x), do: x
      end
      """)["Phoenix"]

    assert md =~ "# Phoenix"
    refute md =~ "##", "expected no function sections — the @doc was on a private def"
    refute md =~ "secret"
  end

  test "skips a module with @moduledoc false" do
    assert docs("""
           defmodule Phoenix.Secret do
             @moduledoc false
             def x, do: 1
           end
           """) == %{}
  end

  test "skips a module with no docs at all" do
    assert docs("""
           defmodule Phoenix.Bare do
             def x, do: 1
           end
           """) == %{}
  end

  test "a syntactically invalid file yields nothing rather than raising" do
    assert docs("""
           defmodule Phoenix.Bad do
             @moduledoc "oops
             def (((
           """) == %{}
  end

  test "a non-literal @moduledoc is skipped without crashing" do
    md =
      docs("""
      defmodule Phoenix.Dyn do
        @moduledoc File.read!("README.md")

        @doc "still documented"
        def f(opts), do: opts
      end
      """)["Phoenix.Dyn"]

    assert md =~ "## f/1"
    refute md =~ "File.read!"
  end
end
