defmodule WriteApi.LinkView do
  @moduledoc "The JSON shape of one link in the dashboard API."

  alias ShortenerCore.Url

  @spec to_map(Url.t(), DateTime.t()) :: map()
  def to_map(%Url{} = url, %DateTime{} = now) do
    %{
      code: url.code,
      short_url: Application.fetch_env!(:write_api, :base_url) <> "/" <> url.code,
      long_url: url.long_url,
      is_custom_alias: url.is_custom_alias,
      created_at: url.created_at,
      expires_at: url.expires_at,
      status: status(url, now)
    }
  end

  defp status(%Url{long_url: nil}, _now), do: "expired"

  defp status(%Url{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt, do: "active", else: "expired"
  end
end
