defmodule ExTermbox.Mixfile do
  use Mix.Project

  def project do
    [
      app: :rrex_termbox,
      version: "2.0.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
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
      # {:termbox2, github: "Hydepwns/termbox2-nif", branch: "master", submodules: true}, # Old Git dependency
      {:termbox2_nif, "~> 0.1.2"}, # Use the published Hex package
      {:earmark_parser, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: [:dev, :test]}
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
      "test.integration": "test --only integration"
    ]
  end
end
