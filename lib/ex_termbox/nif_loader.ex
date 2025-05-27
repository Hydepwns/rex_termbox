defmodule ExTermbox.NIFLoader do
  @moduledoc """
  Handles loading the correct NIF binary for the current platform.
  Downloads the NIF from GitHub Releases if not present in priv/.
  """

  @github_repo "hydepwns/rrex_termbox"
  @nif_base_name "rrex_termbox_nif"
  @priv_dir Path.join(:code.priv_dir(:rrex_termbox), "")

  # Public API
  def load_nif do
    nif_filename = nif_filename_for_current_platform()
    nif_path = Path.join(@priv_dir, nif_filename)

    unless File.exists?(nif_path) do
      case download_nif(nif_filename, nif_path) do
        :ok -> :ok
        {:error, reason} ->
          raise "Could not download NIF: #{reason}\nTried: #{nif_filename} for #{@github_repo}"
      end
    end

    :ok = :erlang.load_nif(nif_path, 0)
  end

  # Detects the current OS/arch and returns the expected NIF filename
  defp nif_filename_for_current_platform do
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

  # Downloads the NIF from the latest GitHub Release assets
  defp download_nif(nif_filename, dest_path) do
    with {:ok, release} <- fetch_latest_release(),
         {:ok, asset_url} <- find_asset_url(release, nif_filename),
         :ok <- download_file(asset_url, dest_path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_latest_release do
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

  defp find_asset_url(release, nif_filename) do
    asset = Enum.find(release["assets"], fn a -> a["name"] == nif_filename end)
    if asset, do: {:ok, asset["browser_download_url"]}, else: {:error, "Asset not found: #{nif_filename}"}
  end

  defp download_file(url, dest_path) do
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