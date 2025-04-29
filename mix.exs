defmodule ExTermbox.Mixfile do
  use Mix.Project

  def project do
    [
      app: :rrex_termbox,
      version: "1.1.2",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      description: description(),
      package: package(),
      aliases: aliases(),

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
    [extra_applications: [:logger]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:expty, "~> 0.2"},
      {:earmark_parser, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyze, "~> 0.2.0", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "An Elixir wrapper for the termbox C library using a Port/UDS helper process."
  end

  defp package do
    [
      files: ~w(
        c_src/termbox_port.c
        c_src/termbox/src/*.{inl,c,h}
        c_src/termbox/**/wscript
        c_src/termbox/waf
        lib
        Makefile
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
      "test.integration": "test --only integration"
    ]
  end
end
