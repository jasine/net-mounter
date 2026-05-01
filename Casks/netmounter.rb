cask "netmounter" do
  version "1.0.1"
  sha256 "16b9de79fc13ab78ee0c02b5c73b55fe6ce299b607c8a38936fb993b060230f2"

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
