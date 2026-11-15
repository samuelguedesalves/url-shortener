import Config

# write_api refuses to boot without SESSION_SECRET (WriteApi.Config.validate!/0).
config :write_api, require_secrets: true

# `mix assets.deploy` (run in the image build) digests the assets and writes this manifest, so the
# layout links `app-<hash>.css` and `app-<hash>.js`. Relative to the write_api app directory.
config :write_api, WriteApi.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
