cask "netmounter" do
  version "1.0.2"
  sha256 "c36c1e72ce625526ffd1ab74e362ed3f002e4ea0f30bc2f9180f0a3fff5f7e56"

  url "https://github.com/jasine/net-mounter/releases/download/v#{version}/NetMounter.dmg"
  name "NetMounter"
  desc "Menu bar app for mounting network shares (SMB, AFP, NFS, WebDAV)"
  homepage "https://github.com/jasine/net-mounter"

  depends_on macos: ">= :sonoma"

  app "NetMounter.app"

  zap trash: [
    "~/Library/Preferences/com.netmounter.app.plist",
    "~/Library/Application Support/NetMounter",
  ]
end
