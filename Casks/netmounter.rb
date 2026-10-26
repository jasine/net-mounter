cask "netmounter" do
  version "1.4.0"
  sha256 "b29a742d5740a0c3d926957f58e887652ba2463d301f46754175c12405f066f4"

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
