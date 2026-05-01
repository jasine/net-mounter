cask "netmounter" do
  version "1.0.0"
  sha256 "9f300ac3ba64fbd5bac4b25d87575147459e9301823512b67957e58c210309d4"

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
