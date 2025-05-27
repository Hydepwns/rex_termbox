defmodule ExTermbox.NIFLoader do
  @moduledoc """
  Handles loading the correct NIF binary for the current platform.
  Downloads the NIF from GitHub Releases if not present in priv/.
  """

  @github_repo "hydepwns/rrex_termbox"
  @nif_base_name "rrex_termbox_nif"
  @_priv_dir Path.join(:code.priv_dir(:rrex_termbox), "")

  # Public API
  def load_nif do
    paths = nif_paths()
    case Enum.find(paths, &File.exists?/1) do
      nil ->
        # Try to download the NIF for the first path (preferred platform-specific)
        [first_path | _] = paths
        nif_filename = Path.basename(first_path)
        case _download_nif(nif_filename, first_path) do
          :ok ->
            try_load_nif([first_path | tl(paths)])
          {:error, reason} ->
            raise "Could not find or download NIF: #{nif_filename}. Reason: #{inspect(reason)}"
        end
      _ ->
        try_load_nif(paths)
    end
  end

  # Detects the current OS/arch and returns the expected NIF filename
  defp _nif_basename do
    {os, ext} = case :os.type() do
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
    "#{@nif_base_name}-#{os}.#{ext}"
  end

  defp nif_paths do
    priv_dir = :code.priv_dir(:rrex_termbox)
    {os, base} = case :os.type() do
      {:unix, :darwin} ->
        arch = to_string(:erlang.system_info(:system_architecture))
        if String.contains?(arch, "arm") or String.contains?(arch, "aarch64") do
          {"darwin", "rrex_termbox_nif-aarch64-apple-darwin"}
        else
          {"darwin", "rrex_termbox_nif-x86_64-apple-darwin"}
        end
      {:unix, :linux} ->
        {"linux", "rrex_termbox_nif-x86_64-unknown-linux-gnu"}
      {:win32, _} ->
        {"windows", "rrex_termbox_nif-x86_64-pc-windows-msvc"}
    end

    case os do
      "darwin" ->
        [
          Path.join(priv_dir, base <> ".dylib"),
          Path.join(priv_dir, base <> ".so")
        ]
      "linux" ->
        [Path.join(priv_dir, base <> ".so")]
      "windows" ->
        [Path.join(priv_dir, base <> ".dll")]
    end
  end

  # Tries to load the NIF from a list of possible paths
  defp try_load_nif([]), do: :erlang.nif_error("No NIF library found for this platform.")
  defp try_load_nif([path | rest]) do
    try do
      :erlang.load_nif(path, 0)
    rescue
      ErlangError ->
        try_load_nif(rest)
    catch
      :error, _ ->
        try_load_nif(rest)
    end
  end

  # Downloads the NIF from the latest GitHub Release assets
  defp _download_nif(nif_filename, dest_path) do
    with {:ok, release} <- _fetch_latest_release(),
         {:ok, asset_url} <- _find_asset_url(release, nif_filename),
         :ok <- _download_file(asset_url, dest_path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp _fetch_latest_release do
    url = "https://api.github.com/repos/#{@github_repo}/releases/latest"
    headers = [{"User-Agent", "ElixirNIFLoader"}]
    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}
      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "GitHub API returned status #{code}"}
      {:error, err} ->
        {:error, inspect(err)}
    end
  end

  defp _find_asset_url(release, nif_filename) do
    asset = Enum.find(release["assets"], fn a -> a["name"] == nif_filename end)
    if asset, do: {:ok, asset["browser_download_url"]}, else: {:error, "Asset not found: #{nif_filename}"}
  end

  defp _download_file(url, dest_path) do
    case HTTPoison.get(url, [], follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        File.write(dest_path, body)
      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "Download failed with status #{code}"}
      {:error, err} ->
        {:error, inspect(err)}
    end
  end
end 