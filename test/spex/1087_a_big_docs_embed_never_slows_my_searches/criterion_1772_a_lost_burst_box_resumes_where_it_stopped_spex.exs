defmodule CodeMySpecSpex.Story1087.Criterion1772Spex do
  @moduledoc """
  Story 1087 — A big docs embed never slows my searches.
  Criterion 1772 — A lost burst box resumes where it stopped.

  A bulk embedding job may not finish in one pass. What already finished
  must not be redone, and what didn't must still get done.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessedKnowledgeHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    {:ok, dir} = Briefly.create(directory: true)
    :ok = Fixtures.embed_on_pgvector(dir)
    Req.Test.set_req_test_to_shared()
    :ok
  end

  @pkg_a %{
    "lib/pkg_a.ex" => "defmodule PkgA do\n  @moduledoc \"PkgA finished before the box died.\"\nend\n"
  }
  @pkg_b %{
    "lib/pkg_b.ex" =>
      "defmodule PkgB do\n  @moduledoc \"PkgB was still unembedded when the box died.\"\nend\n"
  }

  defp lock(entries) do
    body =
      Enum.map_join(entries, ",\n  ", fn {name, version, checksum} ->
        ~s("#{name}": {:hex, :#{name}, "#{version}", "chk", [:mix], [], "hexpm", "#{checksum}"})
      end)

    "%{\n  #{body}\n}\n"
  end

  defp serve(tarballs) do
    Req.Test.stub(CodeMySpec.Embeddings.HexPackageFetch, fn conn ->
      [_, name] = Regex.run(~r/([a-z_]+)-[^-]+\.tar$/, conn.request_path)
      Plug.Conn.send_resp(conn, 200, Map.fetch!(tarballs, name))
    end)
  end

  spex "A lost burst box resumes embedding where it stopped", criterion: 1772 do
    scenario "half a docs set was embedded when the burst box died" do
      given_ "pkg_a finished embedding before the box died, and pkg_b had not started",
              context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball_a, checksum_a} = Fixtures.hex_tarball(@pkg_a)
        {tarball_b, checksum_b} = Fixtures.hex_tarball(@pkg_b)
        serve(%{"pkg_a" => tarball_a, "pkg_b" => tarball_b})

        write_lock(main, lock([{"pkg_a", "1.0.0", checksum_a}]))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "PkgA finished before the box died."
        _ = embedded()

        write_lock(
          main,
          lock([{"pkg_a", "1.0.0", checksum_a}, {"pkg_b", "1.0.0", checksum_b}])
        )

        manifest(main)
        :ok = Fixtures.fail_embedding(true)
        :ok = Fixtures.hex_doc_sweep_runs()
        _ = embedded()
        {:ok, Map.put(context, :main, main)}
      end

      when_ "embedding resumes", context do
        :ok = Fixtures.fail_embedding(false)
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, Map.put(context, :resumed_batches, embedded())}
      end

      then_ "only the unembedded half is embedded", context do
        assert Enum.any?(context.resumed_batches, &(&1 =~ "PkgB was still unembedded")),
               "expected pkg_b to be embedded on resume, got: #{inspect(context.resumed_batches)}"

        {:ok, context}
      end

      then_ "the already-embedded half is not redone", context do
        refute Enum.any?(context.resumed_batches, &(&1 =~ "PkgA finished before the box died.")),
               "pkg_a was re-embedded on resume: #{inspect(context.resumed_batches)}"

        assert search(context.main, "hexdocs") =~ "PkgA finished before the box died."
        assert search(context.main, "hexdocs") =~ "PkgB was still unembedded"
        {:ok, context}
      end
    end
  end
end
