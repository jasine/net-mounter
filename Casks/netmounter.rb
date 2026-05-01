cask "netmounter" do
  version "1.0.1"
  sha256 "d614aaa90160353e30c7f19aca3e93afd9465c9376e4a14bd2cb738cdddc56af"

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
