defmodule ExTermbox.Mixfile do
  use Mix.Project

  def project do
    [
      app: :rrex_termbox,
      version: "2.0.4",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      aliases: aliases(),
      compilers: [:elixir, :app, :nif],

      # Docs
      name: "ExTermbox",
      source_url: "https://github.com/hydepwns/rrex_termbox",
      docs: [
        extras: ["README.md"],
        skip_undefined_reference_warnings_on: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :httpoison]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:termbox2, github: "Hydepwns/termbox2-nif", branch: "master", submodules: true}, # Old Git dependency
      # {:termbox2, "~> 0.1.4"}, # Incorrect Hex package name
      # {:termbox2_nif, "~> 0.1.4", app: :termbox2}, # Specify the underlying app name - disallowed by hex.publish
      # {:termbox2_nif, "~> 0.1.5"}, # Updated version with matching app and package names
      {:earmark_parser, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: [:dev, :test]},
      {:httpoison, "~> 1.8"},
      {:jason, "~> 1.2"}
    ]
  end

  defp description do
    "An Elixir wrapper for the termbox2 C library using NIFs via termbox2_nif."
  end

  defp package do
    [
      files: ~w(
        lib
        mix.exs
        README.md
        LICENSE
      ),
      maintainers: ["DROO AMOR"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/hydepwns/rrex_termbox"}
    ]
  end

  defp aliases do
    [
      test: "test --exclude integration",
      "test.integration": "test --only integration",
      "compile.nif": &compile_nif/1,
      "clean.nif": &clean_nif/1
    ]
  end

  defp compile_nif(_) do
    IO.puts("==> Building NIF in c_src via Makefile...")
    {arch, ext} = case :os.type() do
      {:unix, :darwin} ->
        arch = to_string(:erlang.system_info(:system_architecture))
        if String.contains?(arch, "arm") or String.contains?(arch, "aarch64") do
          {"aarch64-apple-darwin", "dylib"}
        else
          {"x86_64-apple-darwin", "dylib"}
        end
      {:unix, :linux} ->
        {"x86_64-unknown-linux-gnu", "so"}
      {:win32, _} ->
        {"x86_64-pc-windows-msvc", "dll"}
    end
    nif_name = "rrex_termbox_nif-#{arch}.#{ext}"
    # Ensure priv directory exists
    File.mkdir_p!("priv")
    # Run make in c_src
    System.cmd("make", [], cd: "c_src")
    # Find the built NIF (first .so/.dylib/.dll in priv)
    built_nif =
      File.ls!("priv")
      |> Enum.find(fn f -> String.starts_with?(f, "rrex_termbox.") and (String.ends_with?(f, ".so") or String.ends_with?(f, ".dylib") or String.ends_with?(f, ".dll")) end)

    if built_nif do
      File.cp!(Path.join("priv", built_nif), Path.join("priv", nif_name))
      IO.puts("==> NIF built and copied to priv/#{nif_name}")
    else
      Mix.raise("NIF build failed: no NIF binary found in priv/")
    end
  end

  defp clean_nif(_) do
    IO.puts("==> Cleaning NIF build artifacts...")
    # Ensure priv directory exists
    File.mkdir_p!("priv")
    # Remove all NIF binaries from priv/
    File.ls!("priv")
    |> Enum.filter(fn f -> String.starts_with?(f, "rrex_termbox") and (String.ends_with?(f, ".so") or String.ends_with?(f, ".dylib") or String.ends_with?(f, ".dll")) end)
    |> Enum.each(fn f -> File.rm!(Path.join("priv", f)) end)
    # Run make clean in c_src
    System.cmd("make", ["clean"], cd: "c_src")
    IO.puts("==> NIF artifacts cleaned.")
  end
end
