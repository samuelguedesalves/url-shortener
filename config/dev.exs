import Config

# Rebuild the dashboard assets and reload the page on change (`mix phx.server`).
config :write_api, WriteApi.Endpoint,
  code_reloader: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:write_api, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:write_api, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css)$",
      ~r"lib/write_api/.*\.ex$"
    ]
  ]
