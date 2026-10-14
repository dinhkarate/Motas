cask "motas" do
  version "0.2.0"
  sha256 "6e2a77afb06b0ba311187a1e498547e220dae140d2a3e9ea8c7df8ec3b8576d7"

  url "https://github.com/dinhkarate/Motas/releases/download/v#{version}/Motas-#{version}.zip"
  name "Motas"
  desc "Menu bar AI quota monitor for CLIProxyAPI and 9Router proxies"
  homepage "https://github.com/dinhkarate/Motas"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Motas.app"

  zap trash: [
    "~/Library/Application Support/Motas",
    "~/Library/Group Containers/group.dev.motas",
    "~/Library/Preferences/dev.motas.app.plist",
  ]

  caveats <<~EOS
    Motas is ad-hoc signed, not notarized. Install with:
      brew install --cask --no-quarantine dinhkarate/motas/motas
    After each update macOS asks once to let Motas read its proxy
    credentials from Keychain: open the menu bar panel, click Allow…,
    then choose Always Allow.
  EOS
end
