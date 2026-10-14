cask "motas" do
  version "0.1.0"
  sha256 "843cfb128bb79778b2229c98d967df5c6a40ba5a8532b9ae312f1f554f7ff1ca"
  url "https://github.com/dinhkarate/Motas/releases/download/v#{version}/Motas-#{version}.zip"
  name "Motas"
  desc "Menu bar AI quota monitor for remote proxies: CLIProxyAPI and 9Router (Apple Silicon)"
  homepage "https://github.com/dinhkarate/Motas"
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64
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
